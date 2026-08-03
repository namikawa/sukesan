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
    %w[id status created_at expires_at ttl_hours requester title slot used_at holds]
  end

  before do
    allow(SettingsStore).to receive(:load).and_return(SettingsStore::DEFAULT.merge("api_keys" => api_keys))
  end

  # API のチケット識別子（監査ログ・アクセスログと同じ HMAC 短縮 ID）。
  def api_id(token)
    "~#{MaskedAccessLogger.token_short_id(LOG_TOKEN_ID_KEY, token)}"
  end

  # 書き込み系は JSON ボディで送る（Rack::Test は文字列をそのままボディにする）。
  let(:json_headers) { write_auth.merge("CONTENT_TYPE" => "application/json") }

  def post_json(path, body, headers = write_auth)
    post path, JSON.generate(body), headers.merge("CONTENT_TYPE" => "application/json")
  end

  # レスポンスの短縮 ID から、保存されている実チケットを引く（複数発行しても取り違えない）。
  def issued_ticket(id)
    TicketStore.all.find { |ticket| api_id(ticket["token"]) == id }
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
      expect(ticket.values_at("requester", "title", "slot", "used_at", "holds")).to all(be_nil)
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
      # 枠は書き込み系（bookings）と同形の slot オブジェクトで返す。
      expect(ticket["slot"]).to eq("starts_at" => "2026-08-05T10:00:00+09:00",
                                   "ends_at" => "2026-08-05T10:30:00+09:00")
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
          { "starts_at" => "2026-08-05T10:00:00+09:00", "ends_at" => "2026-08-05T10:30:00+09:00" },
          { "starts_at" => "2026-08-06T14:00:00+09:00", "ends_at" => "2026-08-06T14:30:00+09:00" }
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

  describe "発行 POST /api/v1/tickets" do
    it "201 で発行内容とワンタイム URL を返す" do
      post_json("/api/v1/tickets", {})

      expect(last_response.status).to eq(201)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      expect(last_response.headers["Cache-Control"]).to eq("no-store")

      token = TicketStore.all.first["token"]
      json = JSON.parse(last_response.body)
      expect(json.keys).to match_array(%w[id url status ttl_hours created_at expires_at])
      # 識別子は短縮 ID（生 token を含まない）。生 token は発行直後のこの URL でのみ返す。
      expect(json["id"]).to eq(api_id(token))
      expect(json["id"]).not_to include(token)
      expect(json["url"]).to end_with("/t/#{token}")
      expect(json["status"]).to eq("active")
      expect(json["ttl_hours"]).to eq(24)
      expect(Time.iso8601(json["expires_at"])).to eq(Time.iso8601(json["created_at"]) + (24 * 3600))
    end

    it "ttl_hours は許可値のみ受け付け、省略・許可外は 24 に落とす（fail-closed）" do
      [[{ "ttl_hours" => 72 }, 72], [{ "ttl_hours" => 168 }, 168], [{ "ttl_hours" => "72" }, 72],
       [{}, 24], [{ "ttl_hours" => nil }, 24], [{ "ttl_hours" => "12" }, 24],
       [{ "ttl_hours" => "999" }, 24]].each do |body, expected|
        post_json("/api/v1/tickets", body)

        expect(last_response.status).to eq(201)
        json = JSON.parse(last_response.body)
        expect(json["ttl_hours"]).to eq(expected)
        # 保存内容にも反映され、期限計算（expires_at）と一致する。
        ticket = issued_ticket(json["id"])
        expect(TicketStatus.ttl_hours(ticket)).to eq(expected)
        expect(Time.iso8601(json["expires_at"])).to eq(Time.iso8601(ticket["created_at"]) + (expected * 3600))
      end
    end

    it "read キーでは発行できない（403 insufficient_scope）" do
      post_json("/api/v1/tickets", {}, read_auth)

      expect(last_response.status).to eq(403)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("insufficient_scope")
      expect(TicketStore.all).to be_empty
    end

    it "監査ログに ticket_create を残し、target に API 経由（キーのラベル）を併記する" do
      allow(AuditLog).to receive(:record)
      post_json("/api/v1/tickets", {})

      token = TicketStore.all.first["token"]
      expect(AuditLog).to have_received(:record)
        .with(:ticket_create, ip: "127.0.0.1", target: "#{api_id(token)} via=api:write-sys")
    end
  end

  describe "無効化 POST /api/v1/tickets/:id/revoke" do
    it "未使用のチケットを無効化する" do
      token = TicketStore.create
      post "/api/v1/tickets/#{api_id(token)}/revoke", {}, write_auth

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq(
        "id" => api_id(token), "status" => "revoked", "failed_deletes" => 0
      )
      expect(TicketStore.status(TicketStore.find(token))).to eq("revoked")
    end

    it "仮押さえ中は残った [仮ブロック] イベントも削除する（kill switch）" do
      allow(TokenStore).to receive(:load).and_return({ "access_token" => "fake", "expires_at" => 4_102_444_800 })
      stub_request(:delete, %r{googleapis\.com/calendar/v3/calendars/primary/events/}).to_return(status: 204, body: "")
      token = create_held_ticket

      post "/api/v1/tickets/#{api_id(token)}/revoke", {}, write_auth

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["failed_deletes"]).to eq(0)
      expect(a_request(:delete, %r{googleapis\.com/calendar/v3/calendars/primary/events/}))
        .to have_been_made.times(2)
      expect(TicketStore.status(TicketStore.find(token))).to eq("revoked")
    end

    it "イベントを削除できなくても無効化は成立し、件数を failed_deletes で返す" do
      allow(TokenStore).to receive(:load).and_return(nil) # 未連携（既存の管理画面 revoke と同じ挙動）
      token = create_held_ticket

      post "/api/v1/tickets/#{api_id(token)}/revoke", {}, write_auth

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["failed_deletes"]).to eq(2)
      expect(TicketStore.status(TicketStore.find(token))).to eq("revoked")
    end

    it "使用済み・無効化済みは 409（invalid_state）" do
      used = create_used_ticket
      revoked = TicketStore.create
      TicketStore.revoke(revoked)

      [used, revoked].each do |token|
        post "/api/v1/tickets/#{api_id(token)}/revoke", {}, write_auth
        expect(last_response.status).to eq(409)
        expect(JSON.parse(last_response.body).dig("error", "code")).to eq("invalid_state")
      end
      expect(TicketStore.status(TicketStore.find(used))).to eq("used")
    end

    it "該当が無い ID は 404（not_found）" do
      TicketStore.create
      post "/api/v1/tickets/~deadbeef/revoke", {}, write_auth

      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("not_found")
    end

    it "read キーでは無効化できない（403 insufficient_scope）" do
      token = TicketStore.create
      post "/api/v1/tickets/#{api_id(token)}/revoke", {}, read_auth

      expect(last_response.status).to eq(403)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("insufficient_scope")
      expect(TicketStore.status(TicketStore.find(token))).to eq("active")
    end

    it "監査ログに ticket_revoke を残し、target に API 経由（キーのラベル）を併記する" do
      allow(AuditLog).to receive(:record)
      token = TicketStore.create
      post "/api/v1/tickets/#{api_id(token)}/revoke", {}, write_auth

      expect(AuditLog).to have_received(:record)
        .with(:ticket_revoke, ip: "127.0.0.1", target: "#{api_id(token)} via=api:write-sys")
    end
  end

  describe "リクエストボディ（JSON）" do
    it "JSON として壊れているボディは 400（invalid_params）で、チケットは発行しない" do
      post "/api/v1/tickets", "{\"ttl_hours\":", json_headers

      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("invalid_params")
      expect(TicketStore.all).to be_empty
    end

    it "トップレベルがオブジェクトでないボディは 400（invalid_params）" do
      post "/api/v1/tickets", "[24]", json_headers

      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("invalid_params")
      expect(TicketStore.all).to be_empty
    end

    it "空のボディは既定値（24 時間）で発行できる" do
      post "/api/v1/tickets", "", json_headers

      expect(last_response.status).to eq(201)
      expect(JSON.parse(last_response.body)["ttl_hours"]).to eq(24)
    end

    it "上限（64KB）を超えるボディは 400（invalid_params）で、チケットは発行しない" do
      huge = JSON.generate("ttl_hours" => 24, "padding" => "x" * ApiHelpers::MAX_JSON_BODY_BYTES)
      post "/api/v1/tickets", huge, json_headers

      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("invalid_params")
      expect(TicketStore.all).to be_empty
    end
  end

  describe "書き込みのレート制限" do
    it "キーのラベルごと 10 回/分を超えると 429（rate_limited）" do
      10.times do
        post "/api/v1/tickets", {}, write_auth
        expect(last_response.status).to eq(201)
      end

      post "/api/v1/tickets", {}, write_auth
      expect(last_response.status).to eq(429)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("rate_limited")
    end

    it "参照系（GET）は書き込みのレート制限を消費しない" do
      15.times do
        get "/api/v1/tickets", {}, write_auth
        expect(last_response.status).to eq(200)
      end

      post "/api/v1/tickets", {}, write_auth
      expect(last_response.status).to eq(201)
    end
  end
end
