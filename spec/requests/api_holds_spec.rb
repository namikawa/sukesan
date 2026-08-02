# frozen_string_literal: true

RSpec.describe "他システム向け API /api/v1/holds" do
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
  let(:event_url) { %r{googleapis\.com/calendar/v3/calendars/primary/events/} }
  let(:json_headers) { { "Content-Type" => "application/json" } }
  let(:webhook) { "https://hooks.slack.com/services/T00/B00/xxxx" }

  # 過去・直前拒否（リードタイム）に掛からない十分先の営業日（週末・祝日を避ける）。
  let(:date) { future_business_day }
  let(:slot1) { { "starts_at" => "#{date}T09:00:00+09:00", "ends_at" => "#{date}T09:30:00+09:00" } }
  let(:slot2) { { "starts_at" => "#{date}T10:00:00+09:00", "ends_at" => "#{date}T10:30:00+09:00" } }
  let(:valid_body) { { "slots" => [slot1, slot2], "requester" => "山田", "title" => "打合せ" } }

  before do
    allow(TokenStore).to receive(:load).and_return(token_hash)
    allow(SettingsStore).to receive(:load).and_return(settings)
    stub_request(:get, events_url).to_return(status: 200, body: { "items" => [] }.to_json, headers: json_headers)
    stub_request(:post, events_url).to_return(status: 200, body: "{}", headers: json_headers)
    stub_request(:patch, event_url).to_return(status: 200, body: "{}", headers: json_headers)
    stub_request(:delete, event_url).to_return(status: 204, body: "")
  end

  # Slack 通知はテスト環境では既定で無効（configure しない）。通知を見るテストだけ有効化する。
  after { SlackNotifier.configure(nil) }

  def enable_slack!
    SlackNotifier.configure(webhook)
    stub_request(:post, webhook).to_return(status: 200, body: "ok")
  end

  # API のチケット識別子（監査ログ・アクセスログと同じ HMAC 短縮 ID）。
  def api_id(token)
    "~#{MaskedAccessLogger.token_short_id(LOG_TOKEN_ID_KEY, token)}"
  end

  def post_json(path, body = {}, headers = write_auth)
    post path, JSON.generate(body), headers.merge("CONTENT_TYPE" => "application/json")
  end

  def post_hold(body = valid_body, headers = write_auth)
    post_json("/api/v1/holds", body, headers)
  end

  # 仮押さえを 1 件（候補 2 件）作り、その短縮 ID を返す。
  def create_hold!(body = valid_body)
    post_hold(body)
    JSON.parse(last_response.body).fetch("id")
  end

  def stored_ticket
    TicketStore.all.first
  end

  # 保存済み候補の Google イベント ID（クライアントには返さないため、検証はチケットから取り出す）。
  def hold_event_id(ticket, slot)
    ticket["holds"].find { |hold| hold["slot_start"] == slot["starts_at"] }.fetch("event_id")
  end

  def error_code
    JSON.parse(last_response.body).dig("error", "code")
  end

  def error_message
    JSON.parse(last_response.body).dig("error", "message")
  end

  describe "作成 POST /api/v1/holds" do
    it "201 で仮押さえ内容を返し、チケットを held で保存する" do
      post_hold

      expect(last_response.status).to eq(201)
      expect(last_response.headers["Content-Type"]).to include("application/json")
      expect(last_response.headers["Cache-Control"]).to eq("no-store")

      json = JSON.parse(last_response.body)
      ticket = stored_ticket
      expect(json.keys).to match_array(%w[id status expires_at slots])
      expect(json["id"]).to eq(api_id(ticket["token"]))
      expect(json["status"]).to eq("held")
      expect(json["slots"]).to eq([slot1, slot2])
      # 仮押さえの期限は held_at から 7 日（active の ttl_hours ではない）。
      expect(Time.iso8601(json["expires_at"]))
        .to eq(Time.iso8601(ticket["held_at"]) + TicketStatus::HOLD_TTL_SECONDS)
      expect(TicketStore.status(ticket)).to eq("held")
    end

    it "候補の件数だけ [仮ブロック] のイベントを作成する" do
      post_hold

      created = a_request(:post, events_url)
                .with { |req| JSON.parse(req.body)["summary"] == "[仮ブロック] 打合せ - 山田 (from 調整ツール)" }
      expect(created).to have_been_made.times(2)
    end

    it "生 token・holder_key・イベント ID はレスポンスに含めない（チケットには保存する）" do
      post_hold

      ticket = stored_ticket
      expect(ticket["holder_key"]).to be_a(String)
      expect(ticket["holds"].map { |hold| hold["event_id"] }).to all(match(/\Asukesan[0-9a-f]{40}\z/))
      expect(last_response.body).not_to include(ticket["token"])
      expect(last_response.body).not_to include(ticket["holder_key"])
      expect(last_response.body).not_to include(hold_event_id(ticket, slot1))
    end

    it "仮押さえもチケット一覧に held で並ぶ（内部チケット方式）" do
      id = create_hold!

      get "/api/v1/tickets", {}, write_auth
      ticket = JSON.parse(last_response.body)["tickets"].first
      expect(ticket["id"]).to eq(id)
      expect(ticket["status"]).to eq("held")
      expect(ticket["requester"]).to eq("山田")
      expect(ticket["holds"]).to eq([{ "slot_start" => slot1["starts_at"], "slot_end" => slot1["ends_at"] },
                                     { "slot_start" => slot2["starts_at"], "slot_end" => slot2["ends_at"] }])
    end

    it "private_event を指定すると [仮ブロック] 全件を visibility=private で作成する" do
      post_hold(valid_body.merge("private_event" => true))

      expect(last_response.status).to eq(201)
      expect(a_request(:post, events_url).with(body: hash_including("visibility" => "private")))
        .to have_been_made.times(2)
    end

    it "既定では visibility を付けない（Google の既定に委ねる・回帰）" do
      post_hold

      expect(a_request(:post, events_url).with { |req| !JSON.parse(req.body).key?("visibility") })
        .to have_been_made.times(2)
    end

    describe "入力検証" do
      # 検証エラーでは Google を呼ばず、内部チケットも発行しない（ゴミを残さない）。
      def expect_invalid(body, message_part)
        post_hold(body)

        expect(last_response.status).to eq(400)
        expect(error_code).to eq("invalid_params")
        expect(error_message).to include(message_part)
        expect_nothing_created
      end

      def expect_nothing_created
        expect(a_request(:post, events_url)).not_to have_been_made
        expect(TicketStore.all).to be_empty
      end

      def slots_of(count)
        (0...count).map do |i|
          hour = format("%02d", 9 + i)
          { "starts_at" => "#{date}T#{hour}:00:00+09:00", "ends_at" => "#{date}T#{hour}:30:00+09:00" }
        end
      end

      it "slots の欠落・非配列・0 件・上限超過は 400" do
        expect_invalid(valid_body.except("slots"), "slots")
        expect_invalid(valid_body.merge("slots" => slot1), "slots")
        expect_invalid(valid_body.merge("slots" => []), "slots")
        expect_invalid(valid_body.merge("slots" => slots_of(HoldService::MAX_HOLDS + 1)), "1〜5 件")
      end

      it "slots の要素が非オブジェクト・日時形式不正なら 400" do
        expect_invalid(valid_body.merge("slots" => [slot1["starts_at"]]), "slots の各要素")
        expect_invalid(valid_body.merge("slots" => [slot1.merge("starts_at" => "not-a-time")]), "slots[].starts_at")
        expect_invalid(valid_body.merge("slots" => [slot1.except("ends_at")]), "slots[].ends_at")
      end

      it "時間帯が重なる候補は 400（同一時間帯を二重にブロックしない）" do
        expect_invalid(valid_body.merge("slots" => [slot1, slot1]), "重複")
        overlapped = { "starts_at" => "#{date}T09:15:00+09:00", "ends_at" => "#{date}T09:45:00+09:00" }
        expect_invalid(valid_body.merge("slots" => [slot1, overlapped]), "重複")
      end

      it "requester / title の欠落・文字列以外・上限超過は 400" do
        expect_invalid(valid_body.except("requester"), "requester")
        expect_invalid(valid_body.merge("requester" => 123), "requester")
        expect_invalid(valid_body.merge("title" => "   "), "title")
        expect_invalid(valid_body.merge("title" => "あ" * (MAX_TEXT_LENGTH + 1)), "title")
      end

      it "private_event に真偽値以外を渡すと 400" do
        expect_invalid(valid_body.merge("private_event" => "1"), "private_event")
      end
    end

    describe "仮押さえできない場合" do
      it "枠が空いていなければ 409（slot_taken）で、内部チケットを active で残さない" do
        stub_request(:get, events_url).to_return(
          status: 200,
          body: { "items" => [{ "id" => "busy", "summary" => "終日ブロック",
                                "start" => { "dateTime" => "#{date}T09:00:00+09:00" },
                                "end" => { "dateTime" => "#{date}T18:00:00+09:00" } }] }.to_json,
          headers: json_headers
        )
        post_hold

        expect(last_response.status).to eq(409)
        expect(error_code).to eq("slot_taken")
        expect(a_request(:post, events_url)).not_to have_been_made
        expect(TicketStore.all.map { |ticket| TicketStore.status(ticket) }).to eq(["revoked"])
      end

      it "イベント作成が失敗すれば 502（upstream_error）で、内部チケットを active で残さない" do
        stub_request(:post, events_url).to_return(status: 500, body: "boom")

        expect { post_hold }.to output(/\[HoldService\] 仮押さえの作成失敗/).to_stderr
        expect(last_response.status).to eq(502)
        expect(error_code).to eq("upstream_error")
        expect(last_response.body).not_to include("fake") # トークン等を漏らさない
        expect(TicketStore.all.map { |ticket| TicketStore.status(ticket) }).to eq(["revoked"])
      end

      it "作成途中で失敗したら作成済みイベントを取り消す（[仮ブロック] を残さない）" do
        created_ids = []
        stub_request(:post, events_url).to_return do |request|
          created_ids << JSON.parse(request.body)["id"]
          created_ids.size == 1 ? { status: 200, body: "{}", headers: json_headers } : { status: 500, body: "boom" }
        end

        expect { post_hold }.to output(/\[HoldService\] 仮押さえの作成失敗/).to_stderr
        expect(last_response.status).to eq(502)
        expect(created_ids.size).to eq(2) # 1 件目は成功・2 件目で失敗
        expect(a_request(:delete, %r{events/#{created_ids.first}})).to have_been_made.once
        expect(TicketStore.all.map { |ticket| TicketStore.status(ticket) }).to eq(["revoked"])
      end

      it "未連携なら 503（provider_not_connected）で、チケットを発行しない" do
        allow(TokenStore).to receive(:load).and_return(nil)
        post_hold

        expect(last_response.status).to eq(503)
        expect(error_code).to eq("provider_not_connected")
        expect(a_request(:post, events_url)).not_to have_been_made
        expect(TicketStore.all).to be_empty
      end

      it "read キーでは仮押さえできない（403 insufficient_scope）" do
        post_hold(valid_body, read_auth)

        expect(last_response.status).to eq(403)
        expect(error_code).to eq("insufficient_scope")
        expect(a_request(:post, events_url)).not_to have_been_made
        expect(TicketStore.all).to be_empty
      end
    end

    it "監査ログに hold_created を残し、target に API 経由（キーのラベル）と件数を併記する" do
      allow(AuditLog).to receive(:record)
      post_hold

      expect(AuditLog).to have_received(:record)
        .with(:hold_created, ip: "127.0.0.1",
                             target: "#{api_id(stored_ticket['token'])} via=api:write-sys count=2")
    end

    it "Slack へ API 経由（キーのラベル）・依頼者名・候補日時を含む通知を送る（生 token は含めない）" do
      enable_slack!
      post_hold

      expect(
        a_request(:post, webhook).with do |req|
          text = JSON.parse(req.body)["text"]
          text.include?("仮押さえが入りました（2 件・API 経由: write-sys）") && text.include?("山田") &&
            text.include?("打合せ") && text.scan(%r{\d{1,2}/\d{1,2}（.）\s\d{2}:\d{2}〜\d{2}:\d{2}}).size == 2
        end
      ).to have_been_made
      token = stored_ticket["token"]
      expect(a_request(:post, webhook).with { |req| req.body.include?(token) || req.body.include?("/t/") })
        .not_to have_been_made
    end
  end

  describe "決定 POST /api/v1/holds/:id/confirm" do
    def post_confirm(id, body = { "slot_starts_at" => slot2["starts_at"] }, headers = write_auth)
      post_json("/api/v1/holds/#{id}/confirm", body, headers)
    end

    it "200 で確定内容を返し、チケットを used にして決定イベントの ID を保存する" do
      id = create_hold!
      post_confirm(id)

      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json.keys).to match_array(%w[id status slot meet_link patch_failed failed_deletes])
      expect(json["id"]).to eq(id)
      expect(json["status"]).to eq("used")
      expect(json["slot"]).to eq(slot2)
      expect(json["meet_link"]).to be_nil
      expect(json["patch_failed"]).to be(false)
      expect(json["failed_deletes"]).to eq(0)

      ticket = stored_ticket
      expect(TicketStore.status(ticket)).to eq("used")
      expect(ticket["slot_start"]).to eq(slot2["starts_at"])
      expect(ticket["event_id"]).to match(/\Asukesan[0-9a-f]{40}\z/)
    end

    it "決定イベントは [仮ブロック] を外して更新し、他の候補は削除する" do
      id = create_hold!
      ticket = stored_ticket
      chosen = hold_event_id(ticket, slot2)
      other = hold_event_id(ticket, slot1)
      post_confirm(id)

      expect(a_request(:patch, %r{events/#{chosen}})
        .with { |req| JSON.parse(req.body)["summary"] == "打合せ - 山田 (from 調整ツール)" }).to have_been_made.once
      expect(a_request(:delete, %r{events/#{other}})).to have_been_made.once
      expect(stored_ticket["event_id"]).to eq(chosen)
    end

    it "参加者・招待メール・Meet の指定を反映する（主催者を参加者に加える）" do
      id = create_hold!
      stub_request(:patch, event_url)
        .to_return(status: 200, body: JSON.generate("hangoutLink" => "https://meet.google.com/abc-defg-hij"),
                   headers: json_headers)
      post_confirm(id, { "slot_starts_at" => slot2["starts_at"], "attendees" => ["a@example.com"],
                         "request_meet" => true, "send_invites" => true })

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["meet_link"]).to eq("https://meet.google.com/abc-defg-hij")
      expect(a_request(:patch, event_url).with(query: hash_including("sendUpdates" => "all")))
        .to have_been_made.once
      expect(
        a_request(:patch, event_url).with do |req|
          JSON.parse(req.body)["attendees"] == [{ "email" => "admin@example.com" }, { "email" => "a@example.com" }]
        end
      ).to have_been_made.once
      expect(JSON.generate(stored_ticket)).not_to include("meet.google.com") # 会議 URL は永続化しない
    end

    it "任意項目の検証はゲストの決定と同一基準（決定は行われない）" do
      id = create_hold!
      post_confirm(id, { "slot_starts_at" => slot2["starts_at"], "attendees" => ["not-an-email"] })

      expect(last_response.status).to eq(400)
      expect(error_message).to include("参加者メールアドレスの形式")

      post_confirm(id, { "slot_starts_at" => slot2["starts_at"], "video_url" => "https://zoom.us/j/1",
                         "request_meet" => true })
      expect(last_response.status).to eq(400)
      expect(error_message).to include("同時に指定できません")
      expect(TicketStore.status(stored_ticket)).to eq("held")
    end

    it "slot_starts_at の欠落は 400・保存候補に無い値は 404（仮押さえは維持される）" do
      id = create_hold!
      post_confirm(id, {})

      expect(last_response.status).to eq(400)
      expect(error_message).to include("slot_starts_at")

      post_confirm(id, { "slot_starts_at" => "#{date}T13:00:00+09:00" })
      expect(last_response.status).to eq(404)
      expect(error_code).to eq("not_found")
      expect(TicketStore.status(stored_ticket)).to eq("held")
      expect(a_request(:patch, event_url)).not_to have_been_made
    end

    it "仮押さえ中でないチケットは 409（invalid_state）" do
      post_confirm(api_id(TicketStore.create)) # 未使用（active）
      expect(last_response.status).to eq(409)
      expect(error_code).to eq("invalid_state")

      id = create_hold!
      post_confirm(id)
      expect(last_response.status).to eq(200)
      post_confirm(id) # 決定済み（used）
      expect(last_response.status).to eq(409)
      expect(error_code).to eq("invalid_state")
    end

    it "件名の更新に失敗しても決定は成立し、patch_failed: true を返す" do
      id = create_hold!
      stub_request(:patch, event_url).to_return(status: 500, body: "boom")

      expect { post_confirm(id) }.to output(/\[HoldService\] 決定イベントの更新失敗/).to_stderr
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["patch_failed"]).to be(true)
      expect(TicketStore.status(stored_ticket)).to eq("used")
    end

    it "他候補の削除に失敗した件数を failed_deletes で返す" do
      id = create_hold!
      stub_request(:delete, event_url).to_return(status: 500, body: "boom")

      expect { post_confirm(id) }.to output(/\[HoldService\] 仮押さえイベントの削除失敗/).to_stderr
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["failed_deletes"]).to eq(1)
    end

    it "未連携なら 503 で、仮押さえは held のまま" do
      id = create_hold!
      allow(TokenStore).to receive(:load).and_return(nil)
      post_confirm(id)

      expect(last_response.status).to eq(503)
      expect(error_code).to eq("provider_not_connected")
      expect(TicketStore.status(stored_ticket)).to eq("held")
    end

    it "read キーでは決定できない（403 insufficient_scope）" do
      id = create_hold!
      post_confirm(id, { "slot_starts_at" => slot2["starts_at"] }, read_auth)

      expect(last_response.status).to eq(403)
      expect(error_code).to eq("insufficient_scope")
      expect(TicketStore.status(stored_ticket)).to eq("held")
    end

    # API はセッションを持たないため holder 照合を行わない（write キー＝管理者相当という裁定）。
    it "ゲスト画面で作られた仮押さえも API から決定できる（holder 照合なし）" do
      token = TicketStore.create
      post "/hold", authenticity_token: csrf_token, token: token, requester: "田中", title: "面談",
                    slots: ["#{date}T09:00:00+09:00/#{date}T09:30:00+09:00",
                            "#{date}T10:00:00+09:00/#{date}T10:30:00+09:00"]
      expect(TicketStore.held?(TicketStore.find(token))).to be(true)
      clear_cookies # ホルダーのセッション（holder_key）を持たない状態を模す

      post_confirm(api_id(token))
      expect(last_response.status).to eq(200)
      expect(TicketStore.status(TicketStore.find(token))).to eq("used")
    end

    it "監査ログに hold_confirmed を残し、Slack へ API 経由の通知を送る" do
      id = create_hold!
      allow(AuditLog).to receive(:record)
      enable_slack!
      post_confirm(id)

      expect(AuditLog).to have_received(:record)
        .with(:hold_confirmed, ip: "127.0.0.1", target: "#{id} via=api:write-sys")
      expect(
        a_request(:post, webhook).with do |req|
          text = JSON.parse(req.body)["text"]
          text.include?("仮押さえから 1 件に決定しました（API 経由: write-sys）") && text.include?("山田") &&
            text.match?(%r{\d{1,2}/\d{1,2}（.）\s\d{2}:\d{2}〜\d{2}:\d{2}})
        end
      ).to have_been_made
    end
  end

  describe "候補の個別削除 POST /api/v1/holds/:id/slots/delete" do
    def post_delete(id, body = { "slot_starts_at" => slot1["starts_at"] }, headers = write_auth)
      post_json("/api/v1/holds/#{id}/slots/delete", body, headers)
    end

    it "200 で残りの候補を返し、削除した候補のイベントを消す" do
      id = create_hold!
      removed = hold_event_id(stored_ticket, slot1)
      post_delete(id)

      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json.keys).to match_array(%w[id status slots])
      expect(json["id"]).to eq(id)
      expect(json["status"]).to eq("held")
      expect(json["slots"]).to eq([slot2])
      expect(a_request(:delete, %r{events/#{removed}})).to have_been_made.once
      expect(stored_ticket["holds"].map { |hold| hold["slot_start"] }).to eq([slot2["starts_at"]])
    end

    it "最後の 1 件を削除するとチケットが終了する（cancelled・候補は空）" do
      id = create_hold!
      post_delete(id)
      post_delete(id, { "slot_starts_at" => slot2["starts_at"] })

      expect(last_response.status).to eq(200)
      json = JSON.parse(last_response.body)
      expect(json["status"]).to eq("cancelled")
      expect(json["slots"]).to eq([])
      expect(TicketStore.status(stored_ticket)).to eq("cancelled")
      expect(a_request(:delete, event_url)).to have_been_made.times(2)
    end

    it "保存候補に無い slot_starts_at は 404（候補は変わらない）" do
      id = create_hold!
      post_delete(id, { "slot_starts_at" => "#{date}T13:00:00+09:00" })

      expect(last_response.status).to eq(404)
      expect(error_code).to eq("not_found")
      expect(a_request(:delete, event_url)).not_to have_been_made
      expect(stored_ticket["holds"].size).to eq(2)
    end

    it "仮押さえ中でないチケットは 409（invalid_state）" do
      post_delete(api_id(TicketStore.create))

      expect(last_response.status).to eq(409)
      expect(error_code).to eq("invalid_state")
    end

    it "監査ログに hold_deleted を残す（個別削除はゲスト同様 Slack 通知しない）" do
      id = create_hold!
      allow(AuditLog).to receive(:record)
      enable_slack!
      post_delete(id)

      expect(AuditLog).to have_received(:record)
        .with(:hold_deleted, ip: "127.0.0.1", target: "#{id} via=api:write-sys")
      expect(a_request(:post, webhook)).not_to have_been_made
    end
  end

  describe "全取りやめ POST /api/v1/holds/:id/cancel" do
    def post_cancel(id, headers = write_auth)
      post_json("/api/v1/holds/#{id}/cancel", {}, headers)
    end

    it "200 で cancelled を返し、[仮ブロック] を全件削除する" do
      id = create_hold!
      post_cancel(id)

      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)).to eq("id" => id, "status" => "cancelled", "failed_deletes" => 0)
      expect(a_request(:delete, event_url)).to have_been_made.times(2)
      expect(TicketStore.status(stored_ticket)).to eq("cancelled")
    end

    it "削除できなかった件数を failed_deletes で返す（取りやめ自体は成立する）" do
      id = create_hold!
      stub_request(:delete, event_url).to_return(status: 500, body: "boom")

      expect { post_cancel(id) }.to output(/\[HoldService\] 仮押さえイベントの削除失敗/).to_stderr
      expect(last_response.status).to eq(200)
      expect(JSON.parse(last_response.body)["failed_deletes"]).to eq(2)
      expect(TicketStore.status(stored_ticket)).to eq("cancelled")
    end

    it "二重の取りやめは 409（invalid_state）" do
      id = create_hold!
      post_cancel(id)
      post_cancel(id)

      expect(last_response.status).to eq(409)
      expect(error_code).to eq("invalid_state")
      expect(a_request(:delete, event_url)).to have_been_made.times(2)
    end

    it "監査ログに hold_cancelled を残し、Slack へ API 経由の通知を送る" do
      id = create_hold!
      allow(AuditLog).to receive(:record)
      enable_slack!
      post_cancel(id)

      expect(AuditLog).to have_received(:record)
        .with(:hold_cancelled, ip: "127.0.0.1", target: "#{id} via=api:write-sys")
      expect(
        a_request(:post, webhook).with do |req|
          text = JSON.parse(req.body)["text"]
          text.include?("仮押さえがすべて取りやめられました（API 経由: write-sys）") && text.include?("山田")
        end
      ).to have_been_made
    end
  end

  it "ID が不明なら 404（決定・個別削除・全取りやめ）" do
    post_json("/api/v1/holds/~deadbeef/confirm", { "slot_starts_at" => slot1["starts_at"] })
    expect(last_response.status).to eq(404)

    post_json("/api/v1/holds/~deadbeef/slots/delete", { "slot_starts_at" => slot1["starts_at"] })
    expect(last_response.status).to eq(404)

    post_json("/api/v1/holds/~deadbeef/cancel")
    expect(last_response.status).to eq(404)
    expect(error_code).to eq("not_found")
  end

  # Stage 5 の取消（used → cancelled）は「チケット保存値の event_id」だけを消す。仮押さえ経由で
  # 決定した予約でも event_id が保存されるため、API だけで仮押さえ → 決定 → 取消まで完結する。
  it "API で仮押さえ → 決定した予約は POST /api/v1/bookings/:id/cancel で取り消せる" do
    id = create_hold!
    post_json("/api/v1/holds/#{id}/confirm", { "slot_starts_at" => slot2["starts_at"] })
    expect(last_response.status).to eq(200)
    event_id = stored_ticket["event_id"]

    post_json("/api/v1/bookings/#{id}/cancel")
    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)).to eq("id" => id, "status" => "cancelled", "event_deleted" => true)
    expect(a_request(:delete, %r{events/#{event_id}})).to have_been_made.once
    expect(TicketStore.status(stored_ticket)).to eq("cancelled")
  end
end
