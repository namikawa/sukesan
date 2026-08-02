# frozen_string_literal: true

RSpec.describe "他システム向け API /api/v1/availability" do
  let(:read_key) { "r" * 64 }
  let(:created_at) { "2026-07-01T09:00:00+09:00" }
  let(:api_keys) do
    { "read-sys" => { "digest" => Digest::SHA256.hexdigest(read_key), "created_at" => created_at,
                      "scope" => "read" } }
  end
  let(:auth) { { "HTTP_AUTHORIZATION" => "Bearer #{read_key}" } }
  let(:token_hash) { { "access_token" => "fake", "expires_at" => 4_102_444_800 } }
  let(:settings) { SettingsStore::DEFAULT.merge("api_keys" => api_keys) }

  # 直前・過去のリードタイム除外に掛からない、十分先の営業日（週末・祝日を避ける）。
  let(:date) { future_business_day }

  before do
    allow(TokenStore).to receive(:load).and_return(token_hash)
    allow(SettingsStore).to receive(:load).and_return(settings)
    stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })
  end

  def get_availability(overrides = {}, headers = auth)
    query = { start_date: date.to_s, end_date: date.to_s, duration_minutes: "30" }.merge(overrides)
    get "/api/v1/availability", query, headers
  end

  describe "認証・認可" do
    it "発行済みキーが 1 つもなければ 404（API 自体が存在しない扱い）" do
      allow(SettingsStore).to receive(:load).and_return(SettingsStore::DEFAULT.dup)
      get_availability
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("not_found")
    end

    it "非 loopback（REMOTE_ADDR 偽装）は 403" do
      get_availability({}, auth.merge("REMOTE_ADDR" => "203.0.113.10"))
      expect(last_response.status).to eq(403)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("forbidden")
    end

    it "キーが一致しなければ 401" do
      get_availability({}, "HTTP_AUTHORIZATION" => "Bearer wrong-key-#{'x' * 32}")
      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("unauthorized")
    end

    it "read スコープのキーで呼べる（参照系）" do
      get_availability
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      expect(last_response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  describe "正常系" do
    it "日ごとの空き候補を返す" do
      get_availability
      expect(last_response.status).to eq(200)

      json = JSON.parse(last_response.body)
      expect(json["duration_minutes"]).to eq(30)
      expect(json["capped"]).to be(false)
      expect(json["days"].size).to eq(1)

      day = json["days"].first
      expect(day["date"]).to eq(date.to_s)
      expect(day["slots"].first).to eq(
        "starts_at" => "#{date}T09:00:00+09:00",
        "ends_at" => "#{date}T09:30:00+09:00",
        "lunch_warning" => false
      )
      # 営業時間 09:00〜18:00・30 分刻みの最終候補まで返る。
      expect(day["slots"].last["ends_at"]).to eq("#{date}T18:00:00+09:00")
    end

    it "昼休憩の連続確保が崩れる候補には lunch_warning を立てる" do
      allow(SettingsStore).to receive(:load).and_return(
        settings.merge("lunch_start" => "12:00", "lunch_end" => "13:00", "lunch_minutes" => 60)
      )
      get_availability

      slots = JSON.parse(last_response.body)["days"].first["slots"]
      warned = slots.select { |slot| slot["lunch_warning"] }.map { |slot| slot["starts_at"] }
      expect(warned).to contain_exactly("#{date}T12:00:00+09:00", "#{date}T12:30:00+09:00")
    end

    it "営業日 5 日で打ち切り、capped を true にする" do
      get_availability(end_date: (date + 20).to_s)

      json = JSON.parse(last_response.body)
      expect(json["capped"]).to be(true)
      expect(json["days"].size).to eq(AvailabilitySearch::MAX_BUSINESS_DAYS)
    end

    it "営業日が 1 日も無い期間は days が空（capped は false）" do
      sunday = date + ((7 - date.wday) % 7) # 直近の日曜（既定の営業日は月〜金）
      get_availability(start_date: sunday.to_s, end_date: sunday.to_s)

      json = JSON.parse(last_response.body)
      expect(json["days"]).to eq([])
      expect(json["capped"]).to be(false)
    end
  end

  describe "パラメータ検証" do
    it "start_date が欠落していれば 400（invalid_params）" do
      get "/api/v1/availability", { end_date: date.to_s, duration_minutes: "30" }, auth
      expect(last_response.status).to eq(400)
      json = JSON.parse(last_response.body)
      expect(json.dig("error", "code")).to eq("invalid_params")
      expect(json.dig("error", "message")).to include("start_date")
    end

    it "end_date の形式が不正なら 400（invalid_params）" do
      get_availability(end_date: "2026-13-40")
      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "message")).to include("end_date")
    end

    it "duration_minutes が欠落・非数値・15 分の倍数でない・0 以下なら 400（invalid_params）" do
      ["", "abc", "20", "0", "-30", "30x"].each do |value|
        get_availability(duration_minutes: value)
        expect(last_response.status).to eq(400)
        json = JSON.parse(last_response.body)
        expect(json.dig("error", "code")).to eq("invalid_params")
        expect(json.dig("error", "message")).to include("duration_minutes")
      end
    end
  end

  describe "エラー系" do
    it "未連携（TokenStore.load が nil）は 503（provider_not_connected）" do
      allow(TokenStore).to receive(:load).and_return(nil)
      get_availability
      expect(last_response.status).to eq(503)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("provider_not_connected")
    end

    it "Google API の失敗は 502（upstream_error）に丸め、詳細を出さない" do
      stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
        .to_return(status: 500, body: "boom")
      get_availability
      expect(last_response.status).to eq(502)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("upstream_error")
      expect(last_response.body).not_to include("fake") # トークン等を漏らさない
    end
  end
end
