# frozen_string_literal: true

RSpec.describe "他システム向け API /api/v1/tickets" do
  let(:read_key) { "r" * 64 }
  let(:write_key) { "w" * 64 }
  let(:created_at) { "2026-07-01T09:00:00+09:00" }
  let(:api_keys) do
    {
      "read-sys" => { "digest" => Digest::SHA256.hexdigest(read_key), "created_at" => created_at,
                      "scope" => "read" },
      "write-sys" => { "digest" => Digest::SHA256.hexdigest(write_key), "created_at" => created_at,
                       "scope" => "write" }
    }
  end
  let(:read_auth) { { "HTTP_AUTHORIZATION" => "Bearer #{read_key}" } }
  let(:write_auth) { { "HTTP_AUTHORIZATION" => "Bearer #{write_key}" } }

  # 一覧・詳細で常に同じキーセットを返す（値が無い項目は null）。
  let(:ticket_keys) do
    %w[id status created_at expires_at ttl_hours requester title slot_start slot_end used_at holds]
  end

  before do
    allow(SettingsStore).to receive(:load).and_return(SettingsStore::DEFAULT.merge("api_keys" => api_keys))
  end

  # API のチケット識別子（監査ログ・アクセスログと同じ HMAC 短縮 ID）。
  def api_id(token)
    "~#{MaskedAccessLogger.token_short_id(LOG_TOKEN_ID_KEY, token)}"
  end

  def create_used_ticket
    token = TicketStore.create
    TicketStore.use!(token, attrs: { "requester" => "山田", "title" => "打合せ",
                                     "slot_start" => "2026-08-05T10:00:00+09:00",
                                     "slot_end" => "2026-08-05T10:30:00+09:00" })
    token
  end

  # 候補は保存順（後の日程が先）で持たせ、レスポンスで開始時刻順に整うことを確認できるようにする。
  def create_held_ticket
    token = TicketStore.create
    TicketStore.hold!(token, attrs: {
                        "requester" => "佐藤", "title" => "面談", "holder_key" => "holder-key-1",
                        "holds" => [
                          { "event_id" => "sukesan-evt-2", "slot_start" => "2026-08-06T14:00:00+09:00",
                            "slot_end" => "2026-08-06T14:30:00+09:00" },
                          { "event_id" => "sukesan-evt-1", "slot_start" => "2026-08-05T10:00:00+09:00",
                            "slot_end" => "2026-08-05T10:30:00+09:00" }
                        ]
                      })
    token
  end

  describe "認証・認可" do
    it "発行済みキーが 1 つもなければ 404（API 自体が存在しない扱い）" do
      allow(SettingsStore).to receive(:load).and_return(SettingsStore::DEFAULT.dup)
      get "/api/v1/tickets", {}, read_auth
      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("not_found")
    end

    it "非 loopback（REMOTE_ADDR 偽装）は 403" do
      token = TicketStore.create
      get "/api/v1/tickets/#{api_id(token)}", {}, read_auth.merge("REMOTE_ADDR" => "203.0.113.10")
      expect(last_response.status).to eq(403)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("forbidden")
    end

    it "キーが一致しなければ 401" do
      get "/api/v1/tickets", {}, "HTTP_AUTHORIZATION" => "Bearer wrong-key-#{'x' * 32}"
      expect(last_response.status).to eq(401)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("unauthorized")
    end

    it "read スコープのキーで一覧・詳細を取得できる（参照系）" do
      token = TicketStore.create
      get "/api/v1/tickets", {}, read_auth
      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      expect(last_response.headers["Cache-Control"]).to eq("no-store")

      get "/api/v1/tickets/#{api_id(token)}", {}, read_auth
      expect(last_response.status).to eq(200)
    end
  end

  describe "一覧 GET /api/v1/tickets" do
    it "未使用チケットは共通のキーセットで返し、値が無い項目は null" do
      token = TicketStore.create
      get "/api/v1/tickets", {}, read_auth

      json = JSON.parse(last_response.body)
      expect(json["page"]).to eq(1)
      expect(json["total_pages"]).to eq(1)
      expect(json["tickets"].size).to eq(1)

      ticket = json["tickets"].first
      expect(ticket.keys).to match_array(ticket_keys)
      expect(ticket["id"]).to eq(api_id(token))
      expect(ticket["status"]).to eq("active")
      expect(ticket["ttl_hours"]).to eq(24)
      expected_expiry = Time.iso8601(TicketStore.find(token)["created_at"]) + (24 * 3600)
      expect(Time.iso8601(ticket["expires_at"])).to eq(expected_expiry)
      expect(ticket.values_at("requester", "title", "slot_start", "slot_end", "used_at", "holds")).to all(be_nil)
    end

    it "使用済みチケットは登録内容を返し、期限（expires_at）は null" do
      token = create_used_ticket
      get "/api/v1/tickets", {}, read_auth

      ticket = JSON.parse(last_response.body)["tickets"].first
      expect(ticket.keys).to match_array(ticket_keys)
      expect(ticket["id"]).to eq(api_id(token))
      expect(ticket["status"]).to eq("used")
      expect(ticket["requester"]).to eq("山田")
      expect(ticket["title"]).to eq("打合せ")
      expect(ticket["slot_start"]).to eq("2026-08-05T10:00:00+09:00")
      expect(ticket["slot_end"]).to eq("2026-08-05T10:30:00+09:00")
      expect(ticket["used_at"]).not_to be_nil
      expect(ticket["expires_at"]).to be_nil
      expect(ticket["holds"]).to be_nil
    end

    it "仮押さえ中は候補を開始時刻順に返し、イベント ID は含めない" do
      token = create_held_ticket
      get "/api/v1/tickets", {}, read_auth

      ticket = JSON.parse(last_response.body)["tickets"].first
      expect(ticket["status"]).to eq("held")
      expect(ticket["holds"]).to eq(
        [
          { "slot_start" => "2026-08-05T10:00:00+09:00", "slot_end" => "2026-08-05T10:30:00+09:00" },
          { "slot_start" => "2026-08-06T14:00:00+09:00", "slot_end" => "2026-08-06T14:30:00+09:00" }
        ]
      )
      expect(last_response.body).not_to include("sukesan-evt")
      expect(last_response.body).not_to include("holder-key-1")
      # 仮押さえの期限は held_at から 7 日。
      expected_expiry = Time.iso8601(TicketStore.find(token)["held_at"]) + TicketStatus::HOLD_TTL_SECONDS
      expect(Time.iso8601(ticket["expires_at"])).to eq(expected_expiry)
    end

    it "生 token・ワンタイム URL は一覧に含めない" do
      token = TicketStore.create
      get "/api/v1/tickets", {}, write_auth

      expect(last_response.body).not_to include(token)
      expect(last_response.body).not_to include("/t/")
    end

    it "status で絞り込める" do
      active = TicketStore.create
      used = create_used_ticket

      get "/api/v1/tickets", { status: "used" }, read_auth
      tickets = JSON.parse(last_response.body)["tickets"]
      expect(tickets.map { |t| t["id"] }).to eq([api_id(used)])

      get "/api/v1/tickets", { status: "active" }, read_auth
      tickets = JSON.parse(last_response.body)["tickets"]
      expect(tickets.map { |t| t["id"] }).to eq([api_id(active)])
    end

    it "expired・revoked・cancelled も status で絞り込める" do
      expired = TicketStore.create(now: Time.now - (25 * 3600))
      revoked = TicketStore.create
      TicketStore.revoke(revoked)
      cancelled = create_held_ticket
      TicketStore.cancel_hold!(cancelled)

      { "expired" => expired, "revoked" => revoked, "cancelled" => cancelled }.each do |status, token|
        get "/api/v1/tickets", { status: status }, read_auth
        tickets = JSON.parse(last_response.body)["tickets"]
        expect(tickets.map { |t| t["id"] }).to eq([api_id(token)])
        expect(tickets.first["expires_at"]).to be_nil
      end
    end

    it "許可外の status は 400（invalid_params）" do
      get "/api/v1/tickets", { status: "unknown" }, read_auth
      expect(last_response.status).to eq(400)
      json = JSON.parse(last_response.body)
      expect(json.dig("error", "code")).to eq("invalid_params")
      expect(json.dig("error", "message")).to include("status")
    end

    it "ページングは管理画面と同じ流儀（既定 10 件・ホワイトリスト・クランプ）" do
      11.times { TicketStore.create }

      get "/api/v1/tickets", {}, read_auth
      json = JSON.parse(last_response.body)
      expect(json["tickets"].size).to eq(10)
      expect(json["page"]).to eq(1)
      expect(json["total_pages"]).to eq(2)

      get "/api/v1/tickets", { page: "2" }, read_auth
      expect(JSON.parse(last_response.body)["tickets"].size).to eq(1)

      # 範囲外のページは端へクランプする。
      get "/api/v1/tickets", { page: "99" }, read_auth
      expect(JSON.parse(last_response.body)["page"]).to eq(2)

      # 許可値の per は反映し、許可外は既定（10 件）に落とす。
      get "/api/v1/tickets", { per: "50" }, read_auth
      json = JSON.parse(last_response.body)
      expect(json["tickets"].size).to eq(11)
      expect(json["total_pages"]).to eq(1)

      get "/api/v1/tickets", { per: "7" }, read_auth
      expect(JSON.parse(last_response.body)["total_pages"]).to eq(2)
    end
  end

  describe "詳細 GET /api/v1/tickets/:id" do
    it "短縮 ID（~xxxxxxxx）で 1 件を引ける" do
      token = create_held_ticket
      get "/api/v1/tickets/#{api_id(token)}", {}, read_auth

      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json.keys).to match_array(ticket_keys)
      expect(json["id"]).to eq(api_id(token))
      expect(json["status"]).to eq("held")
      expect(json["holds"].size).to eq(2)
    end

    it "該当が無い ID は 404（not_found）" do
      TicketStore.create
      ["~deadbeef", "not-an-id", "~#{'0' * 8}"].each do |id|
        get "/api/v1/tickets/#{id}", {}, read_auth
        expect(last_response.status).to eq(404)
        expect(JSON.parse(last_response.body).dig("error", "code")).to eq("not_found")
      end
    end

    it "write スコープ かつ active のときだけワンタイム URL を返す" do
      active = TicketStore.create
      used = create_used_ticket

      get "/api/v1/tickets/#{api_id(active)}", {}, write_auth
      json = JSON.parse(last_response.body)
      expect(json["url"]).to end_with("/t/#{active}")

      # read スコープには返さない（active でも）。
      get "/api/v1/tickets/#{api_id(active)}", {}, read_auth
      expect(JSON.parse(last_response.body)).not_to have_key("url")
      expect(last_response.body).not_to include(active)

      # active 以外は write スコープでも返さない。
      get "/api/v1/tickets/#{api_id(used)}", {}, write_auth
      expect(JSON.parse(last_response.body)).not_to have_key("url")
      expect(last_response.body).not_to include(used)

      get "/api/v1/tickets/#{api_id(used)}", {}, read_auth
      expect(JSON.parse(last_response.body)).not_to have_key("url")
    end
  end
end
