# frozen_string_literal: true

RSpec.describe "ワンタイム URL" do
  let(:token_hash) { { "access_token" => "fake", "expires_at" => 4_102_444_800 } }
  let(:settings) do
    {
      "business_start" => "09:00", "business_end" => "18:00", "business_days" => [1, 2, 3, 4, 5],
      "lunch_start" => "11:00", "lunch_end" => "14:00", "lunch_minutes" => 60
    }
  end

  before do
    allow(TokenStore).to receive(:load).and_return(token_hash)
    allow(SettingsStore).to receive(:load).and_return(settings)
  end

  describe "発行 POST /tickets" do
    it "未認証では発行できず /admin へリダイレクト" do
      post "/tickets", authenticity_token: csrf_token
      expect(last_response.status).to eq(302)
      expect(last_response.headers["Location"]).to end_with("/admin")
      expect(TicketStore.all).to be_empty
    end

    it "CSRF トークンが無いと 403" do
      login_admin!
      post "/tickets"
      expect(last_response.status).to eq(403)
    end

    it "管理者なら発行でき、管理画面の一覧に URL とコピーボタンが表示される" do
      login_admin!
      post "/tickets", authenticity_token: csrf_token
      expect(last_response.status).to eq(302)

      token = TicketStore.all.first["token"]
      get "/admin"
      expect(last_response.body).to include("/t/#{token}")
      expect(last_response.body).to include("copy-btn")
    end
  end

  describe "アクセス GET /t/:token" do
    it "有効なトークンなら調整画面（検索フォーム）を表示する" do
      token = TicketStore.create
      get "/t/#{token}"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("action=\"/t/#{token}\"")
      expect(last_response.body).to include("空き時間をチェック")
    end

    it "存在しないトークンは 410 で案内を表示する" do
      get "/t/does-not-exist"
      expect(last_response.status).to eq(410)
      expect(last_response.body).to include("無効")
    end

    it "使用済みトークンは 410 で完了案内を表示する" do
      token = TicketStore.create
      TicketStore.use!(token, attrs: { "requester" => "山田", "title" => "打合せ" })
      get "/t/#{token}"
      expect(last_response.status).to eq(410)
      expect(last_response.body).to include("完了")
    end
  end

  describe "無効化 POST /tickets/:token/revoke" do
    it "管理者は有効なトークンを無効化できる" do
      token = TicketStore.create
      login_admin!
      post "/tickets/#{token}/revoke", authenticity_token: csrf_token
      expect(last_response.status).to eq(302)
      expect(TicketStore.status(TicketStore.find(token))).to eq("revoked")
    end

    it "未認証では無効化できない" do
      token = TicketStore.create
      post "/tickets/#{token}/revoke", authenticity_token: csrf_token
      expect(last_response.status).to eq(302)
      expect(TicketStore.status(TicketStore.find(token))).to eq("active")
    end
  end
end
