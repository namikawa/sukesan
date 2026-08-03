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
  # 単一イベントの URL（末尾に ID が続く）。一覧取得（?timeMin=…）とは一致しない。
  let(:single_event_url) { %r{googleapis\.com/calendar/v3/calendars/primary/events/} }

  # 過去・直前拒否（リードタイム）に掛からない十分先の営業日（週末・祝日を避ける）。
  let(:slot_date) { future_business_day }
  let(:slot) { { "starts_at" => "#{slot_date}T09:00:00+09:00", "ends_at" => "#{slot_date}T09:30:00+09:00" } }
  let(:valid_body) { { "slot" => slot, "requester" => "山田", "title" => "打合せ" } }

  before do
    allow(TokenStore).to receive(:load).and_return(token_hash)
    allow(SettingsStore).to receive(:load).and_return(settings)
    stub_request(:get, events_url)
      .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })
    # 登録失敗後の存在確認（get_event）は既定で「作られていない」（404）。
    stub_get_event
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

  # 登録失敗後に呼ぶ存在確認（GET /events/<id>）のスタブ。既定は 404＝Google 側にも作られていない。
  def stub_get_event(status: 404, body: "")
    stub_request(:get, single_event_url)
      .to_return(status: status, body: body, headers: { "Content-Type" => "application/json" })
  end

  # 登録リクエストのボディを記録しつつ成功を返すスタブ（送信した event id の検証に使う）。
  def stub_create_capturing(captured)
    stub_request(:post, events_url)
      .with { |request| captured << JSON.parse(request.body) }
      .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
  end

  # 同じ event id が既にある（409）ときの Google の応答。
  def stub_conflict
    stub_request(:post, events_url)
      .to_return(status: 409, body: JSON.generate("error" => { "code" => 409, "message" => "duplicate" }),
                 headers: { "Content-Type" => "application/json" })
  end

  # Idempotency-Key 付きで 1 件登録し、その短縮 ID を返す。
  def create_used_booking_with_key!(key = "key-1")
    stub_create
    post_with_key(key)
    JSON.parse(last_response.body).fetch("id")
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

      # 存在確認（既定 404）でも予定が見つからないため、従来どおり失敗として扱う。
      expect { post_booking }.to output(/\[BookingService\] 登録失敗/).to_stderr
      expect(last_response.status).to eq(502)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("upstream_error")
      expect(last_response.body).not_to include("fake") # トークン等を漏らさない
      expect(TicketStore.all.map { |ticket| TicketStore.status(ticket) }).to eq(["revoked"])
    end

    # 応答を受け取れなくても Google 側では作成できていることがある（タイムアウト等）。存在を確認して
    # 回収しないと、sukesan の管理外になった予定がカレンダーに残る（空き再検証が塞がれ再試行もできない）。
    it "応答を受け取れなくても Google 側に予定があれば 201（チケットは used のまま・会議リンクも回収）" do
      stub_request(:post, events_url).to_return(status: 500, body: "boom")
      stub_get_event(status: 200,
                     body: JSON.generate("id" => "sukesanev1", "status" => "confirmed",
                                         "hangoutLink" => "https://meet.google.com/abc-defg-hij"))
      post_booking(valid_body.merge("request_meet" => true))

      expect(last_response.status).to eq(201)
      expect(JSON.parse(last_response.body)["meet_link"]).to eq("https://meet.google.com/abc-defg-hij")
      expect(TicketStore.status(stored_ticket)).to eq("used")
    end

    it "存在確認自体が失敗したら 502（曖昧なら失敗側へ倒し、チケットは終端させる）" do
      stub_request(:post, events_url).to_return(status: 500, body: "boom")
      stub_get_event(status: 500, body: "boom")

      expect { post_booking }.to output(/登録結果の確認失敗/).to_stderr
      expect(last_response.status).to eq(502)
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

    it "キー未指定なら Google の 409（同じ token での再試行＝作成済み）は既存扱いで成立する（201）" do
      stub_conflict
      post_booking

      expect(last_response.status).to eq(201)
      expect(JSON.parse(last_response.body)["meet_link"]).to be_nil
      expect(TicketStore.status(stored_ticket)).to eq("used")
    end

    # Google は削除したイベントの ID を再利用できないため、取消済みの予約と同じキーを使うと登録できない。
    # リプレイ検索は used のチケットしか見ないため、ここで成功に丸めるとカレンダーに予定が無いまま 201 になる。
    it "取り消した予約と同じキーでの再登録は 409（idempotency_conflict）で、チケットを終端させる" do
      id = create_used_booking_with_key!
      stub_request(:delete, events_url).to_return(status: 204, body: "")
      post "/api/v1/bookings/#{id}/cancel", "{}", write_auth.merge("CONTENT_TYPE" => "application/json")
      expect(last_response.status).to eq(200)

      stub_conflict
      allow(AuditLog).to receive(:record)
      post_with_key("key-1")

      expect(last_response.status).to eq(409)
      json = JSON.parse(last_response.body)
      expect(json.dig("error", "code")).to eq("idempotency_conflict")
      expect(json.dig("error", "message")).to include("Idempotency-Key")
      # 取消済みの元チケットは cancelled のまま、再登録の内部チケットは active で残さず終端させる。
      expect(TicketStore.all.map { |ticket| TicketStore.status(ticket) }).to contain_exactly("cancelled", "revoked")
      expect(AuditLog).to have_received(:record)
        .with(:booking_failed, ip: "127.0.0.1", target: a_string_including("via=api:write-sys"))
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

  # 取消は sukesan にとって新しい遷移（used → cancelled）。削除対象の event id はチケット保存値のみを使う。
  describe "取消 POST /api/v1/bookings/:id/cancel" do
    def event_url(event_id)
      "https://www.googleapis.com/calendar/v3/calendars/primary/events/#{event_id}"
    end

    def post_cancel(id, body = {}, headers = write_auth)
      post "/api/v1/bookings/#{id}/cancel", JSON.generate(body), headers.merge("CONTENT_TYPE" => "application/json")
    end

    def stub_delete(status: 204)
      stub_request(:delete, events_url).to_return(status: status, body: "")
    end

    # 直接予約（POST /api/v1/bookings）で used のチケットを 1 枚作り、その短縮 ID を返す。
    def create_booking!
      stub_create
      post_booking
      JSON.parse(last_response.body).fetch("id")
    end

    it "200 で cancelled を返し、チケット保存値の event id を削除する（既定は通知なし）" do
      id = create_booking!
      event_id = stored_ticket["event_id"]
      stub_delete
      post_cancel(id)

      expect(last_response.status).to eq(200)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      expect(last_response.headers["Cache-Control"]).to eq("no-store")
      expect(JSON.parse(last_response.body)).to eq("id" => id, "status" => "cancelled", "event_deleted" => true)
      expect(a_request(:delete, event_url(event_id)).with(query: { "sendUpdates" => "none" })).to have_been_made
    end

    it "チケットを cancelled にし、取消日時と登録内容を残す（一覧 API でも cancelled で並ぶ）" do
      id = create_booking!
      stub_delete
      post_cancel(id)

      ticket = stored_ticket
      expect(TicketStore.status(ticket)).to eq("cancelled")
      expect(ticket["cancelled_at"]).not_to be_nil
      # 登録内容は残るため、仮押さえの全取りやめ（slot_start を持たない cancelled）と区別できる。
      expect(ticket["slot_start"]).to eq(slot["starts_at"])

      get "/api/v1/tickets", { "status" => "cancelled" }, write_auth
      expect(JSON.parse(last_response.body)["tickets"].map { |t| t["id"] }).to eq([id])
    end

    it "notify_attendees を指定すると参加者へキャンセル通知を送る（sendUpdates=all）" do
      id = create_booking!
      event_id = stored_ticket["event_id"]
      stub_delete
      post_cancel(id, { "notify_attendees" => true })

      expect(last_response.status).to eq(200)
      expect(a_request(:delete, event_url(event_id)).with(query: { "sendUpdates" => "all" })).to have_been_made
    end

    it "notify_attendees に真偽値以外を渡すと 400 で、チケットは used のまま" do
      id = create_booking!
      delete_stub = stub_delete
      post_cancel(id, { "notify_attendees" => "1" })

      expect(last_response.status).to eq(400)
      expect(JSON.parse(last_response.body).dig("error", "message")).to include("notify_attendees")
      expect(delete_stub).not_to have_been_requested
      expect(TicketStore.status(stored_ticket)).to eq("used")
    end

    it "仮押さえから決定した予約も取り消せる（決定時に保存した event_id を削除する）" do
      stub_create
      stub_request(:patch, events_url)
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
      stub_delete
      token = TicketStore.create
      post "/hold", authenticity_token: csrf_token, token: token, requester: "山田", title: "打合せ",
                    slots: ["#{slot_date}T09:00:00+09:00/#{slot_date}T09:30:00+09:00",
                            "#{slot_date}T10:00:00+09:00/#{slot_date}T10:30:00+09:00"]
      post "/hold/confirm", authenticity_token: csrf_token, token: token, slot: "#{slot_date}T10:00:00+09:00"

      ticket = TicketStore.find(token)
      expect(TicketStore.status(ticket)).to eq("used")
      expect(ticket["event_id"]).to match(/\Asukesan[0-9a-f]{40}\z/) # 決定したイベントの ID を保存している

      post_cancel(api_id(token))
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["event_deleted"]).to be(true)
      expect(TicketStore.status(TicketStore.find(token))).to eq("cancelled")
      expect(a_request(:delete, event_url(ticket["event_id"])).with(query: { "sendUpdates" => "none" }))
        .to have_been_made
    end

    # 遷移の探索範囲（SEARCH_WEEKS＝3 週）より古くても、一覧（直近 30 日）に並ぶ予約は取り消せる
    # （「詳細は見えるのに取消だけ 409」という食い違いを作らない）。
    it "4 週間前に登録した予約も取り消せる（一覧に並ぶ範囲は取消の対象）" do
      created = Time.now - (28 * 86_400)
      token = TicketStore.create(now: created)
      TicketStore.use!(token, now: created,
                              attrs: { "requester" => "山田", "title" => "打合せ",
                                       "slot_start" => slot["starts_at"], "slot_end" => slot["ends_at"],
                                       "event_id" => "sukesanold" })
      stub_delete
      post_cancel(api_id(token))

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["status"]).to eq("cancelled")
      expect(a_request(:delete, event_url("sukesanold")).with(query: { "sendUpdates" => "none" }))
        .to have_been_made
    end

    it "event_id を保存していない used は取り消せない（409・event_id 保存前に登録された予約）" do
      token = TicketStore.create
      TicketStore.use!(token, attrs: { "requester" => "山田", "title" => "打合せ",
                                       "slot_start" => slot["starts_at"], "slot_end" => slot["ends_at"] })
      delete_stub = stub_delete
      post_cancel(api_id(token))

      expect(last_response.status).to eq(409)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("invalid_state")
      expect(delete_stub).not_to have_been_requested
      expect(TicketStore.status(TicketStore.find(token))).to eq("used")
    end

    it "未使用（active）は 409（invalid_state）" do
      stub_delete
      post_cancel(api_id(TicketStore.create))

      expect(last_response.status).to eq(409)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("invalid_state")
    end

    it "取消済みは 409（二重取消はできない・Google も再度呼ばない）" do
      id = create_booking!
      delete_stub = stub_delete
      post_cancel(id)
      post_cancel(id)

      expect(last_response.status).to eq(409)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("invalid_state")
      expect(delete_stub).to have_been_requested.times(1)
    end

    it "該当が無い ID は 404（not_found）" do
      create_booking!
      post_cancel("~deadbeef")

      expect(last_response.status).to eq(404)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("not_found")
      expect(TicketStore.status(stored_ticket)).to eq("used")
    end

    it "未連携なら 503 で、チケットは used のまま（予定を消せないのに遷移だけ進めない）" do
      id = create_booking!
      allow(TokenStore).to receive(:load).and_return(nil)
      delete_stub = stub_delete
      post_cancel(id)

      expect(last_response.status).to eq(503)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("provider_not_connected")
      expect(delete_stub).not_to have_been_requested
      expect(TicketStore.status(stored_ticket)).to eq("used")
    end

    it "予定の削除に失敗しても取消は成立し、event_deleted: false を返す（残った予定は手動で掃除）" do
      id = create_booking!
      stub_delete(status: 500)

      expect { post_cancel(id) }.to output(/\[api\] 予約イベントの削除失敗/).to_stderr
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["event_deleted"]).to be(false)
      expect(TicketStore.status(stored_ticket)).to eq("cancelled")
    end

    it "Google 側に予定が無い（404）場合も削除済みとして event_deleted: true（冪等）" do
      id = create_booking!
      stub_delete(status: 404)
      post_cancel(id)

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["event_deleted"]).to be(true)
      expect(TicketStore.status(stored_ticket)).to eq("cancelled")
    end

    it "read キーでは取り消せない（403 insufficient_scope）" do
      id = create_booking!
      delete_stub = stub_delete
      post_cancel(id, {}, read_auth)

      expect(last_response.status).to eq(403)
      expect(JSON.parse(last_response.body).dig("error", "code")).to eq("insufficient_scope")
      expect(delete_stub).not_to have_been_requested
      expect(TicketStore.status(stored_ticket)).to eq("used")
    end

    it "監査ログに booking_cancelled を残し、target に API 経由（キーのラベル）を併記する" do
      id = create_booking!
      stub_delete
      allow(AuditLog).to receive(:record)
      post_cancel(id)

      expect(AuditLog).to have_received(:record)
        .with(:booking_cancelled, ip: "127.0.0.1", target: "#{id} via=api:write-sys")
    end

    describe "Slack 通知" do
      let(:webhook) { "https://hooks.slack.com/services/T00/B00/xxxx" }

      before do
        SlackNotifier.configure(webhook)
        stub_request(:post, webhook).to_return(status: 200, body: "ok")
      end
      after { SlackNotifier.configure(nil) } # テスト既定（no-op）へ戻す

      def notification_including(text_part)
        a_request(:post, webhook).with { |req| JSON.parse(req.body)["text"].include?(text_part) }
      end

      it "取消時に API 経由（キーのラベル）と依頼者名・件名・日時を含む通知を送る" do
        id = create_booking!
        stub_delete
        post_cancel(id)

        expect(
          a_request(:post, webhook).with do |req|
            text = JSON.parse(req.body)["text"]
            text.include?("予約が取り消されました（API 経由: write-sys）") && text.include?("山田") &&
              text.include?("打合せ") && text.match?(%r{\d{1,2}/\d{1,2}（.）\s\d{2}:\d{2}〜\d{2}:\d{2}})
          end
        ).to have_been_made
        expect(notification_including("手動で削除")).not_to have_been_made
      end

      it "予定を削除できなかった場合は手動での削除を促す注記を付ける" do
        id = create_booking!
        stub_delete(status: 500)

        expect { post_cancel(id) }.to output(/予約イベントの削除失敗/).to_stderr
        expect(notification_including("手動で削除")).to have_been_made
      end
    end
  end
end
