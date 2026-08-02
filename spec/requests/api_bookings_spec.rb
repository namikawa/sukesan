# frozen_string_literal: true

RSpec.describe "他システム向け API /api/v1/bookings" do
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
  let(:token_hash) { { "access_token" => "fake", "expires_at" => 4_102_444_800, "admin_email" => "admin@example.com" } }
  let(:settings) { SettingsStore::DEFAULT.merge("api_keys" => api_keys) }
  let(:events_url) { %r{googleapis\.com/calendar/v3/calendars/primary/events} }

  # 過去・直前拒否（リードタイム）に掛からない十分先の営業日（週末・祝日を避ける）。
  let(:slot_date) { future_business_day }
  let(:slot) { { "starts_at" => "#{slot_date}T09:00:00+09:00", "ends_at" => "#{slot_date}T09:30:00+09:00" } }
  let(:valid_body) { { "slot" => slot, "requester" => "山田", "title" => "打合せ" } }

  before do
    allow(TokenStore).to receive(:load).and_return(token_hash)
    allow(SettingsStore).to receive(:load).and_return(settings)
    stub_request(:get, events_url)
      .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })
  end

  # API のチケット識別子（監査ログ・アクセスログと同じ HMAC 短縮 ID）。
  def api_id(token)
    "~#{MaskedAccessLogger.token_short_id(LOG_TOKEN_ID_KEY, token)}"
  end

  def post_booking(body = valid_body, headers = write_auth)
    post "/api/v1/bookings", JSON.generate(body), headers.merge("CONTENT_TYPE" => "application/json")
  end

  def post_with_key(key, body = valid_body)
    post_booking(body, write_auth.merge("HTTP_IDEMPOTENCY_KEY" => key))
  end

  def stub_create(response = {})
    stub_request(:post, events_url)
      .to_return(status: 200, body: JSON.generate(response), headers: { "Content-Type" => "application/json" })
  end

  # 登録リクエストのボディを記録しつつ成功を返すスタブ（送信した event id の検証に使う）。
  def stub_create_capturing(captured)
    stub_request(:post, events_url)
      .with { |request| captured << JSON.parse(request.body) }
      .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
  end

  def stored_ticket
    TicketStore.all.first
  end

  describe "正常系" do
    it "201 で登録内容を返し、内部チケットを used で保存する" do
      create = stub_create
      post_booking

      expect(last_response.status).to eq(201)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      expect(last_response.headers["Cache-Control"]).to eq("no-store")
      expect(create).to have_been_requested

      json = JSON.parse(last_response.body)
      expect(json.keys).to match_array(%w[id status slot meet_link])
      expect(json["id"]).to eq(api_id(stored_ticket["token"]))
      expect(json["status"]).to eq("used")
      expect(json["slot"]).to eq("starts_at" => slot["starts_at"], "ends_at" => slot["ends_at"])
      expect(json["meet_link"]).to be_nil
    end

    it "チケットに登録内容と event id を保存する（生 token はレスポンスに含めない）" do
      stub_create
      post_booking(valid_body.merge("attendees" => ["a@example.com"]))

      ticket = stored_ticket
      expect(TicketStore.status(ticket)).to eq("used")
      expect(ticket["requester"]).to eq("山田")
      expect(ticket["title"]).to eq("打合せ")
      expect(ticket["slot_start"]).to eq(slot["starts_at"])
      expect(ticket["slot_end"]).to eq(slot["ends_at"])
      expect(ticket["attendees"]).to eq(["a@example.com"])
      expect(ticket["event_id"]).to match(/\Asukesan[0-9a-f]{40}\z/)
      expect(ticket).not_to have_key("idempotency_key")
      expect(last_response.body).not_to include(ticket["token"])
    end

    it "主催者を参加者に加えて登録し、既定は sendUpdates=none・visibility なし" do
      create = stub_request(:post, events_url)
               .with(query: hash_including("sendUpdates" => "none"),
                     body: hash_including("attendees" => [{ "email" => "admin@example.com" },
                                                          { "email" => "a@example.com" }]))
               .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
      post_booking(valid_body.merge("attendees" => ["a@example.com"]))

      expect(last_response.status).to eq(201)
      expect(create).to have_been_requested
      expect(a_request(:post, events_url).with { |req| !JSON.parse(req.body).key?("visibility") }).to have_been_made
    end

    it "send_invites / private_event を指定すると sendUpdates=all・visibility=private で登録する" do
      create = stub_request(:post, events_url)
               .with(query: hash_including("sendUpdates" => "all"), body: hash_including("visibility" => "private"))
               .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
      post_booking(valid_body.merge("send_invites" => true, "private_event" => true))

      expect(last_response.status).to eq(201)
      expect(create).to have_been_requested
    end

    it "ビデオ会議 URL は説明欄に載せ、チケットには保存しない" do
      create = stub_request(:post, events_url)
               .with(body: hash_including("description" => "依頼者: 山田\nビデオ会議: https://zoom.us/j/1"))
               .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
      post_booking(valid_body.merge("video_url" => "https://zoom.us/j/1"))

      expect(last_response.status).to eq(201)
      expect(create).to have_been_requested
      expect(JSON.generate(stored_ticket)).not_to include("zoom.us")
    end

    it "request_meet 時は会議リンクを応答で返し、チケットには永続化しない" do
      stub_create({ "hangoutLink" => "https://meet.google.com/abc-defg-hij" })
      post_booking(valid_body.merge("request_meet" => true))

      expect(last_response.status).to eq(201)
      expect(JSON.parse(last_response.body)["meet_link"]).to eq("https://meet.google.com/abc-defg-hij")
      expect(JSON.generate(stored_ticket)).not_to include("meet.google.com")
    end

    it "登録した予約はチケット一覧にも並ぶ（内部チケット方式）" do
      stub_create
      post_booking
      id = JSON.parse(last_response.body)["id"]

      get "/api/v1/tickets", {}, write_auth
      ticket = JSON.parse(last_response.body)["tickets"].first
      expect(ticket["id"]).to eq(id)
      expect(ticket["status"]).to eq("used")
      expect(ticket["requester"]).to eq("山田")
      expect(ticket["title"]).to eq("打合せ")
    end
  end

  describe "認可" do
    it "read キーでは登録できない（403 insufficient_scope）" do
      create = stub_create
      post_booking(valid_body, read_auth)

      expect(last_response.status).to eq(403)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("insufficient_scope")
      expect(create).not_to have_been_requested
      expect(TicketStore.all).to be_empty
    end
  end

  describe "入力検証" do
    # 検証エラーでは Google を呼ばず、内部チケットも発行しない（ゴミを残さない）。
    def expect_invalid(body, message_part)
      create = stub_create
      post_booking(body)

      expect_invalid_params(message_part)
      expect(create).not_to have_been_requested
      expect(TicketStore.all).to be_empty
    end

    def expect_invalid_params(message_part)
      expect(last_response.status).to eq(400)
      json = JSON.parse(last_response.body)
      expect(json.dig("error", "code")).to eq("invalid_params")
      expect(json.dig("error", "message")).to include(message_part)
    end

    it "slot の欠落・型不正・日時形式不正は 400" do
      expect_invalid(valid_body.except("slot"), "slot")
      expect_invalid(valid_body.merge("slot" => "#{slot_date}T09:00:00+09:00"), "slot")
      expect_invalid(valid_body.merge("slot" => slot.merge("starts_at" => "not-a-time")), "slot.starts_at")
      expect_invalid(valid_body.merge("slot" => slot.except("ends_at")), "slot.ends_at")
    end

    it "requester / title の欠落・空白のみ・文字列以外・上限超過は 400" do
      expect_invalid(valid_body.except("requester"), "requester")
      expect_invalid(valid_body.merge("requester" => 123), "requester")
      expect_invalid(valid_body.merge("title" => "   "), "title")
      expect_invalid(valid_body.merge("title" => "あ" * (MAX_TEXT_LENGTH + 1)), "title")
    end

    it "attendees は文字列の配列のみ受け、件数・形式はゲストと同一基準" do
      expect_invalid(valid_body.merge("attendees" => "a@example.com"), "attendees")
      expect_invalid(valid_body.merge("attendees" => [123]), "attendees")
      expect_invalid(valid_body.merge("attendees" => ["not-an-email"]), "参加者メールアドレスの形式")
      too_many = Array.new(ScheduleHelpers::MAX_ATTENDEES + 1) { |i| "a#{i}@example.com" }
      expect_invalid(valid_body.merge("attendees" => too_many), "参加者は最大")
    end

    it "真偽値の項目に文字列を渡すと 400（\"1\" や \"true\" を真として扱わない）" do
      %w[request_meet send_invites private_event].each do |name|
        expect_invalid(valid_body.merge(name => "1"), name)
        expect_invalid(valid_body.merge(name => "true"), name)
      end
    end

    it "video_url は文字列・http(s) のみで、Meet 発行との同時指定は 400" do
      expect_invalid(valid_body.merge("video_url" => 1), "video_url")
      expect_invalid(valid_body.merge("video_url" => "javascript:alert(1)"), "ビデオ会議 URL の形式")
      expect_invalid(valid_body.merge("video_url" => "https://zoom.us/j/1", "request_meet" => true),
                     "同時に指定できません")
    end
  end

  describe "登録できない場合" do
    it "枠が埋まっていれば 409（slot_taken）で、内部チケットを active で残さない" do
      stub_request(:get, events_url).to_return(
        status: 200,
        body: { "items" => [{ "id" => "busy", "summary" => "終日ブロック",
                              "start" => { "dateTime" => "#{slot_date}T09:00:00+09:00" },
                              "end" => { "dateTime" => "#{slot_date}T18:00:00+09:00" } }] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
      create = stub_create
      post_booking

      expect(last_response.status).to eq(409)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("slot_taken")
      expect(create).not_to have_been_requested
      expect(TicketStore.all.map { |ticket| TicketStore.status(ticket) }).to eq(["revoked"])
    end

    it "Google 登録が失敗すれば 502（upstream_error）で、内部チケットを active で残さない" do
      stub_request(:post, events_url).to_return(status: 500, body: "boom")

      expect { post_booking }.to output(/\[BookingService\] 登録失敗/).to_stderr
      expect(last_response.status).to eq(502)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("upstream_error")
      expect(last_response.body).not_to include("fake") # トークン等を漏らさない
      expect(TicketStore.all.map { |ticket| TicketStore.status(ticket) }).to eq(["revoked"])
    end

    it "未連携なら 503（provider_not_connected）で、チケットを発行しない" do
      allow(TokenStore).to receive(:load).and_return(nil)
      create = stub_create
      post_booking

      expect(last_response.status).to eq(503)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("provider_not_connected")
      expect(create).not_to have_been_requested
      expect(TicketStore.all).to be_empty
    end
  end

  describe "冪等性（Idempotency-Key）" do
    it "同じキーの 2 回目はリプレイ（200・Google 登録は 1 回・チケットは増えない）" do
      create = stub_create({ "hangoutLink" => "https://meet.google.com/abc-defg-hij" })
      post_with_key("key-1", valid_body.merge("request_meet" => true))
      expect(last_response.status).to eq(201)
      first = JSON.parse(last_response.body)
      expect(first["meet_link"]).to eq("https://meet.google.com/abc-defg-hij")

      post_with_key("key-1", valid_body.merge("request_meet" => true))
      expect(last_response.status).to eq(200)
      replayed = JSON.parse(last_response.body)
      expect(replayed["id"]).to eq(first["id"])
      expect(replayed["status"]).to eq("used")
      expect(replayed["slot"]).to eq(first["slot"])
      # 会議 URL は永続化しないため、リプレイでは返せない（初回応答でのみ返る）。
      expect(replayed["meet_link"]).to be_nil
      expect(create).to have_been_requested.times(1)
      expect(TicketStore.all.size).to eq(1)
    end

    it "キーをチケットに保存し、Google の event id もキー由来にする（token 由来とは別）" do
      captured = []
      stub_create_capturing(captured)
      post_with_key("key-1")
      expect(last_response.status).to eq(201)

      # 保存・導出に使う値は API キーのラベルでスコープされる（"<ラベル>:<キー>"）。
      expected_id = BookingService.event_id(EVENT_ID_KEY, "idem:write-sys:key-1")
      expect(stored_ticket["idempotency_key"]).to eq("write-sys:key-1")
      expect(stored_ticket["event_id"]).to eq(expected_id)
      expect(captured.map { |body| body["id"] }).to eq([expected_id])
      expect(expected_id).not_to eq(BookingService.event_id(EVENT_ID_KEY, stored_ticket["token"]))
    end

    it "異なるキーは別の予約として登録する" do
      create = stub_create
      post_with_key("key-1")
      post_with_key("key-2")

      expect(last_response.status).to eq(201)
      expect(create).to have_been_requested.times(2)
      expect(TicketStore.all.size).to eq(2)
    end

    it "冪等キーは API キー（ラベル）単位でスコープし、別システムの同名キーとは衝突しない" do
      create = stub_create
      post_with_key("key-1")
      expect(last_response.status).to eq(201)

      # 別ラベルの write キーが偶然同じキー文字列を使っても、リプレイにならず自分の予約が作られる。
      other_key = "o" * 64
      keys = api_keys.merge("other-sys" => { "digest" => Digest::SHA256.hexdigest(other_key),
                                             "created_at" => created_at, "scope" => "write" })
      allow(SettingsStore).to receive(:load).and_return(SettingsStore::DEFAULT.merge("api_keys" => keys))
      post_booking(valid_body, { "HTTP_AUTHORIZATION" => "Bearer #{other_key}",
                                 "HTTP_IDEMPOTENCY_KEY" => "key-1" })

      expect(last_response.status).to eq(201)
      expect(create).to have_been_requested.times(2)
      expect(TicketStore.all.size).to eq(2)
    end

    it "キー未指定なら従来どおり毎回新規登録し、event id は token 由来（リトライ保護なし）" do
      captured = []
      stub_create_capturing(captured)
      post_booking
      post_booking

      expect(TicketStore.all.size).to eq(2)
      expect(captured.size).to eq(2)
      expect(captured.map { |body| body["id"] }.uniq.size).to eq(2)
      expect(TicketStore.all.map { |ticket| BookingService.event_id(EVENT_ID_KEY, ticket["token"]) })
        .to match_array(captured.map { |body| body["id"] })
    end

    it "リプレイの対象は used のチケットだけ（失敗して無効化されたキーは再実行できる）" do
      stub_request(:post, events_url).to_return(status: 500, body: "boom")
      expect { post_with_key("key-1") }.to output(/\[BookingService\] 登録失敗/).to_stderr
      expect(last_response.status).to eq(502)

      stub_create
      post_with_key("key-1")
      expect(last_response.status).to eq(201)
      expect(TicketStore.all.map { |ticket| TicketStore.status(ticket) }).to contain_exactly("used", "revoked")
    end

    it "レース時に同じ event id で Google が 409 を返しても既存扱いで成立する（201）" do
      stub_request(:post, events_url)
        .to_return(status: 409, body: JSON.generate("error" => { "code" => 409, "message" => "duplicate" }),
                   headers: { "Content-Type" => "application/json" })
      post_with_key("key-1")

      expect(last_response.status).to eq(201)
      expect(JSON.parse(last_response.body)["meet_link"]).to be_nil
      expect(TicketStore.status(stored_ticket)).to eq("used")
    end

    it "上限（128 文字）を超えるキーは 400 で、チケットを発行しない" do
      create = stub_create
      post_with_key("k" * 129)

      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "message")).to include("Idempotency-Key")
      expect(create).not_to have_been_requested
      expect(TicketStore.all).to be_empty
    end
  end

  describe "監査ログ" do
    it "登録成功時に booking_created を残し、target に API 経由（キーのラベル）を併記する" do
      allow(AuditLog).to receive(:record)
      stub_create
      post_booking

      expect(AuditLog).to have_received(:record)
        .with(:booking_created, ip: "127.0.0.1", target: "#{api_id(stored_ticket['token'])} via=api:write-sys")
    end

    it "登録失敗時は booking_failed を残す（後始末の無効化は記録しない）" do
      allow(AuditLog).to receive(:record)
      stub_request(:post, events_url).to_return(status: 500, body: "boom")

      expect { post_booking }.to output(/\[BookingService\] 登録失敗/).to_stderr
      expect(AuditLog).to have_received(:record)
        .with(:booking_failed, ip: "127.0.0.1", target: "#{api_id(stored_ticket['token'])} via=api:write-sys")
      # 内部チケットの無効化は後始末なので記録しない（監査は予約の成否のみ）。
      expect(AuditLog).to have_received(:record).once
    end

    it "リプレイ応答では監査ログを残さない" do
      stub_create
      post_with_key("key-1")

      allow(AuditLog).to receive(:record)
      post_with_key("key-1")
      expect(last_response.status).to eq(200)
      expect(AuditLog).not_to have_received(:record)
    end
  end

  # Slack 通知はテスト環境では既定で無効（configure しない）。通知テストのときだけ configure する。
  describe "Slack 通知" do
    let(:webhook) { "https://hooks.slack.com/services/T00/B00/xxxx" }

    before do
      SlackNotifier.configure(webhook)
      stub_create
      stub_request(:post, webhook).to_return(status: 200, body: "ok")
    end
    after { SlackNotifier.configure(nil) } # テスト既定（no-op）へ戻す

    it "登録完了時に API 経由（キーのラベル）と依頼者名・日時を含む通知を送る" do
      post_booking
      expect(last_response.status).to eq(201)
      expect(
        a_request(:post, webhook).with do |req|
          text = JSON.parse(req.body)["text"]
          text.include?("新規のスケジュールが追加されました（API 経由: write-sys）") && text.include?("山田") &&
            text.include?("打合せ") && text.match?(%r{\d{1,2}/\d{1,2}（.）\s\d{2}:\d{2}〜\d{2}:\d{2}})
        end
      ).to have_been_made
    end

    it "通知に生 token・チケット URL は含めない" do
      post_booking
      token = stored_ticket["token"]
      expect(a_request(:post, webhook).with { |req| req.body.include?(token) || req.body.include?("/t/") })
        .not_to have_been_made
    end

    it "リプレイ応答では通知しない" do
      post_with_key("key-1")
      post_with_key("key-1")

      expect(last_response.status).to eq(200)
      expect(a_request(:post, webhook)).to have_been_made.times(1)
    end
  end
end
