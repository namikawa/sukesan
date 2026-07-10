# frozen_string_literal: true

RSpec.describe "API キーの発行・削除 /settings/api_keys" do
  # SettingsStore をメモリ上のハッシュで代替し、実ファイル（data/settings.json）を汚さない
  # （load→merge→save の意味論を保ったモック）。
  let(:settings_data) { {} }

  before do
    allow(SettingsStore).to receive(:load) { SettingsStore::DEFAULT.merge(settings_data) }
    allow(SettingsStore).to receive(:save) do |attrs|
      settings_data.merge!(attrs.transform_keys(&:to_s))
    end
  end

  def issue_key(label)
    post "/settings/api_keys", authenticity_token: csrf_token, label: label
  end

  # 発行直後の画面から生のキー（64 文字 hex）を取り出す。
  def displayed_key
    last_response.body[/id="new-api-key">([0-9a-f]{64})</, 1]
  end

  it "未ログインの POST は /admin へリダイレクトし、保存しない" do
    post "/settings/api_keys", authenticity_token: csrf_token, label: "sysA"
    expect(last_response.status).to eq(302)
    expect(last_response.headers["Location"]).to end_with("/admin")
    expect(SettingsStore).not_to have_received(:save)

    post "/settings/api_keys/delete", authenticity_token: csrf_token, label: "sysA"
    expect(last_response.headers["Location"]).to end_with("/admin")
    expect(SettingsStore).not_to have_received(:save)
  end

  describe "ログイン済み" do
    before { login_admin! }

    it "発行するとキーを一度だけ表示し、再表示しない（保存はダイジェストのみ）" do
      issue_key("sysA")
      expect(last_response.status).to eq(302)

      follow_redirect!
      key = displayed_key
      expect(key).to match(/\A[0-9a-f]{64}\z/)
      expect(last_response.body).to include("この画面を離れると再表示できません")
      expect(last_response.body).to include("sysA")

      # コピーボタンは外部 JS ファイル経由（CSP 維持のためインラインスクリプト・イベントハンドラは使わない）。
      expect(last_response.body).to include('<script src="/settings.js"></script>')
      expect(last_response.body).to include('id="api-key-copy"')
      expect(last_response.body).to include('data-target="new-api-key"')
      expect(last_response.body).not_to include("onclick=")
      expect(last_response.body).not_to include("<script>") # インラインスクリプトの直書き禁止

      # 保存されるのはダイジェストのみ（生のキーは永続化しない）。
      saved = settings_data["api_keys"]["sysA"]
      expect(saved["digest"]).to eq(Digest::SHA256.hexdigest(key))
      expect(saved.values).not_to include(key)

      # 再表示（リロード）ではキーを出さない。一覧（ラベル・作成日時・削除ボタン）は表示する。
      get "/settings"
      expect(last_response.body).not_to include(key)
      expect(last_response.body).to include("sysA")
      expect(last_response.body).to include("/settings/api_keys/delete")
    end

    it "発行したキーで API 認証が通る" do
      allow(TokenStore).to receive(:load)
        .and_return({ "access_token" => "fake", "expires_at" => 4_102_444_800 })
      stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
        .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })

      issue_key("sysA")
      follow_redirect!
      key = displayed_key

      get "/api/v1/calendars/google/events", {}, "HTTP_AUTHORIZATION" => "Bearer #{key}"
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["events"]).to eq([])
    end

    it "ラベル検証: 空・長すぎ・重複・件数上限は発行しない" do
      issue_key("  ")
      follow_redirect!
      expect(last_response.body).to include("システム名を入力してください")
      expect(settings_data["api_keys"]).to be_nil

      issue_key("a" * 51)
      follow_redirect!
      expect(last_response.body).to include("システム名が長すぎます")
      expect(settings_data["api_keys"]).to be_nil

      issue_key("sysA")
      issue_key("sysA")
      follow_redirect!
      expect(last_response.body).to include("既に発行されています")
      expect(settings_data["api_keys"].size).to eq(1)

      settings_data["api_keys"] = (1..20).to_h do |i|
        ["sys#{i}", { "digest" => "d", "created_at" => "2026-07-01T09:00:00+09:00" }]
      end
      issue_key("sys21")
      follow_redirect!
      expect(last_response.body).to include("上限")
      expect(settings_data["api_keys"].size).to eq(20)
    end

    it "削除するとそのキーは即座に 401 になる（他のキーは有効なまま）" do
      issue_key("sysA")
      follow_redirect!
      key_a = displayed_key
      issue_key("sysB")

      post "/settings/api_keys/delete", authenticity_token: csrf_token, label: "sysA"
      expect(last_response.status).to eq(302)
      expect(settings_data["api_keys"].keys).to eq(["sysB"])

      get "/api/v1/calendars/google/events", {}, "HTTP_AUTHORIZATION" => "Bearer #{key_a}"
      expect(last_response.status).to eq(401)
    end

    it "存在しないラベルの削除は何も消さず、通知を表示する" do
      issue_key("sysA")
      post "/settings/api_keys/delete", authenticity_token: csrf_token, label: "nope"
      follow_redirect!
      expect(last_response.body).to include("見つかりません")
      expect(settings_data["api_keys"].keys).to eq(["sysA"])
    end

    it "発行・削除を監査ログに記録する（キー本体・ダイジェストは出さない）" do
      allow(AuditLog).to receive(:record)
      issue_key("sysA")
      expect(AuditLog).to have_received(:record).with(:api_key_issued, ip: anything, target: "sysA")

      follow_redirect!
      key = displayed_key
      post "/settings/api_keys/delete", authenticity_token: csrf_token, label: "sysA"
      expect(AuditLog).to have_received(:record).with(:api_key_revoked, ip: anything, target: "sysA")
      expect(AuditLog).not_to have_received(:record)
        .with(anything, hash_including(target: a_string_including(key)))
    end

    it "ラベルの HTML はエスケープして表示する（保存型 XSS の回帰）" do
      issue_key("<b>evil")
      follow_redirect!
      expect(last_response.body).to include("&lt;b&gt;evil")
      expect(last_response.body).not_to include("<b>evil")
    end
  end
end
