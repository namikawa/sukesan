# frozen_string_literal: true

RSpec.describe "他システム向け API /api/v1/calendars/google/events" do
  # 発行済みキー: サーバ側には SHA-256 ダイジェストのみ保存されている（画面発行方式）。
  let(:api_key) { "k" * 64 }
  let(:api_keys) do
    { "test-sys" => { "digest" => Digest::SHA256.hexdigest(api_key), "created_at" => "2026-07-01T09:00:00+09:00" } }
  end
  let(:auth) { { "HTTP_AUTHORIZATION" => "Bearer #{api_key}" } }
  let(:token_hash) { { "access_token" => "fake", "expires_at" => 4_102_444_800, "admin_email" => "admin@example.com" } }

  # Google Calendar API の 1 件分のレスポンス（時間指定イベント）。
  def google_event(id:, summary:, start_dt:, end_dt:, location: nil)
    { "id" => id, "summary" => summary, "location" => location,
      "start" => { "dateTime" => start_dt }, "end" => { "dateTime" => end_dt } }
  end

  before do
    allow(TokenStore).to receive(:load).and_return(token_hash)
    allow(SettingsStore).to receive(:load).and_return(SettingsStore::DEFAULT.merge("api_keys" => api_keys))
  end

  describe "認証・認可" do
    it "発行済みキーが 1 つもなければ 404（API 自体が存在しない扱い）" do
      allow(SettingsStore).to receive(:load).and_return(SettingsStore::DEFAULT.dup)
      get "/api/v1/calendars/google/events", {}, auth
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("not_found")
    end

    it "Authorization ヘッダなしは 401" do
      get "/api/v1/calendars/google/events"
      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("unauthorized")
    end

    it "不正なキーは 401 で、監査ログに api_auth_failed を記録する" do
      allow(AuditLog).to receive(:record)
      get "/api/v1/calendars/google/events", {}, "HTTP_AUTHORIZATION" => "Bearer wrong-key-#{'x' * 32}"
      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("unauthorized")
      expect(AuditLog).to have_received(:record).with(:api_auth_failed, ip: "127.0.0.1")
    end

    it "非 loopback（REMOTE_ADDR 偽装）は 403" do
      get "/api/v1/calendars/google/events", {}, auth.merge("REMOTE_ADDR" => "203.0.113.10")
      expect(last_response.status).to eq(403)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("forbidden")
    end

    it "認証成功でも応答は Content-Type: application/json ＋ Cache-Control: no-store" do
      stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
        .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })
      get "/api/v1/calendars/google/events", {}, auth
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      expect(last_response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  describe "正常系" do
    before do
      body = { "items" => [
        google_event(id: "evt-1", summary: "朝会", location: "会議室 A",
                     start_dt: "2026-07-10T10:00:00+09:00", end_dt: "2026-07-10T11:00:00+09:00")
      ] }
      stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
        .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
    end

    it "date 省略時は今日を対象に 200 を返し、レスポンス形式を満たす" do
      get "/api/v1/calendars/google/events", {}, auth
      expect(last_response.status).to eq(200)

      json = JSON.parse(last_response.body)
      expect(json["date"]).to eq(Date.today.strftime("%F"))
      expect(json["events"]).to be_an(Array)
      event = json["events"].first
      expect(event).to eq(
        "id" => "evt-1",
        "title" => "朝会",
        "starts_at" => "2026-07-10T10:00:00+09:00",
        "ends_at" => "2026-07-10T11:00:00+09:00",
        "location" => "会議室 A",
        "all_day" => false
      )
    end

    it "date 省略時は当日 0:00〜翌日 0:00（Asia/Tokyo）で Google API を呼ぶ" do
      get "/api/v1/calendars/google/events", {}, auth

      today = Date.today
      time_min = Time.local(today.year, today.month, today.day)
      time_max = time_min + (24 * 60 * 60)
      expect(
        a_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
          .with(query: hash_including(
            "timeMin" => time_min.utc.iso8601,
            "timeMax" => time_max.utc.iso8601
          ))
      ).to have_been_made
    end

    it "date 指定時はその日の範囲（Asia/Tokyo）で Google API を呼び、date をそのまま返す" do
      get "/api/v1/calendars/google/events", { date: "2026-07-15" }, auth
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["date"]).to eq("2026-07-15")

      expect(
        a_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
          .with(query: hash_including(
            "timeMin" => Time.local(2026, 7, 15).utc.iso8601,
            "timeMax" => (Time.local(2026, 7, 15) + (24 * 60 * 60)).utc.iso8601
          ))
      ).to have_been_made
    end
  end

  describe "エラー系" do
    it "不正な date は 400（invalid_date）" do
      get "/api/v1/calendars/google/events", { date: "2026-13-40" }, auth
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("invalid_date")
    end

    it "未連携（TokenStore.load が nil）は 503（provider_not_connected）" do
      allow(TokenStore).to receive(:load).and_return(nil)
      get "/api/v1/calendars/google/events", {}, auth
      expect(last_response.status).to eq(503)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("provider_not_connected")
    end

    it "Google API の失敗は 502（upstream_error）に丸め、詳細を出さない" do
      stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
        .to_return(status: 500, body: "boom")
      get "/api/v1/calendars/google/events", {}, auth
      expect(last_response.status).to eq(502)
      json = JSON.parse(last_response.body)
      expect(json.dig("error", "code")).to eq("upstream_error")
      expect(last_response.body).not_to include("fake") # トークン等を漏らさない
    end

    it "レート制限（60 回/60 秒）超過は 429（rate_limited）" do
      stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
        .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })
      60.times do
        get "/api/v1/calendars/google/events", {}, auth
        expect(last_response.status).to eq(200)
      end
      get "/api/v1/calendars/google/events", {}, auth
      expect(last_response.status).to eq(429)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("rate_limited")
    end
  end
end
