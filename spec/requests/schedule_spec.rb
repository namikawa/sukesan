# frozen_string_literal: true

RSpec.describe "予定作成 /schedule" do
  let(:token_hash) { { "access_token" => "fake", "expires_at" => 4_102_444_800, "admin_email" => "admin@example.com" } }
  let(:settings) do
    {
      "business_start" => "09:00", "business_end" => "18:00", "business_days" => [1, 2, 3, 4, 5],
      "lunch_start" => "11:00", "lunch_end" => "14:00", "lunch_minutes" => 60
    }
  end
  # 過去・直前拒否（リードタイム）に掛からないよう、十分先の営業日（平日）を使う。
  def future_weekday
    d = Date.today + 7
    d += 1 until (1..5).cover?(d.wday)
    d
  end

  def past_weekday
    d = Date.today - 7
    d -= 1 until (1..5).cover?(d.wday)
    d
  end

  let(:slot_date) { future_weekday }
  let(:valid_slot) { "#{slot_date}T09:00:00+09:00/#{slot_date}T09:30:00+09:00" }
  # 登録には有効なワンタイム URL（token）が必須。
  let(:token) { TicketStore.create }

  before do
    allow(TokenStore).to receive(:load).and_return(token_hash)
    allow(SettingsStore).to receive(:load).and_return(settings)
    stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })
  end

  it "CSRF トークンが無いと 403" do
    post "/schedule", token: token, title: "t", requester: "r", slot: valid_slot
    expect(last_response.status).to eq(403)
  end

  it "token が無い（または無効）と 403" do
    post "/schedule", authenticity_token: csrf_token, title: "t", requester: "r", slot: valid_slot
    expect(last_response.status).to eq(403)
  end

  it "不正な slot 形式は 400" do
    post "/schedule", authenticity_token: csrf_token, token: token, title: "t", requester: "r", slot: "notatime"
    expect(last_response.status).to eq(400)
  end

  it "依頼者名が無いと 400" do
    post "/schedule", authenticity_token: csrf_token, token: token, title: "t", slot: valid_slot
    expect(last_response.status).to eq(400)
  end

  it "15 の倍数でない長さ（UI 迂回の1分枠）は 422" do
    post "/schedule", authenticity_token: csrf_token, token: token, title: "t", requester: "r",
                      slot: "#{slot_date}T09:00:00+09:00/#{slot_date}T09:01:00+09:00"
    expect(last_response.status).to eq(422)
  end

  it "候補に無い時間帯（営業時間外）は 422" do
    post "/schedule", authenticity_token: csrf_token, token: token, title: "t", requester: "r",
                      slot: "#{slot_date}T03:00:00+09:00/#{slot_date}T04:00:00+09:00"
    expect(last_response.status).to eq(422)
  end

  it "過去の時間帯は 422" do
    past = past_weekday
    post "/schedule", authenticity_token: csrf_token, token: token, title: "t", requester: "r",
                      slot: "#{past}T09:00:00+09:00/#{past}T09:30:00+09:00"
    expect(last_response.status).to eq(422)
  end

  it "正当な候補なら予定を作成して 302 を返し、token を使用済みにする" do
    create = stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token,
                      title: "打合せ", requester: "山田", slot: valid_slot
    expect(last_response.status).to eq(302)
    expect(create).to have_been_requested
    expect(TicketStore.status(TicketStore.find(token))).to eq("used")
  end

  it "使用済みの token では再登録できず 403" do
    stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token,
                      title: "打合せ", requester: "山田", slot: valid_slot
    # 同じ token で再登録を試みる（使用済みのため弾かれる）。
    post "/schedule", authenticity_token: csrf_token, token: token,
                      title: "打合せ2", requester: "佐藤", slot: valid_slot
    expect(last_response.status).to eq(403)
  end

  it "参加者（改行・カンマ・スペース区切り）と主催者を attendees に登録する" do
    create = stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
             .with(body: hash_including(
               "attendees" => [
                 { "email" => "admin@example.com" }, { "email" => "a@example.com" },
                 { "email" => "b@example.com" }, { "email" => "c@example.com" }
               ]
             ))
             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token, title: "打合せ", requester: "山田",
                      slot: valid_slot, attendees: "a@example.com, b@example.com\nc@example.com"
    expect(last_response.status).to eq(302)
    expect(create).to have_been_requested
  end

  it "参加者未入力でも主催者（自分）が attendees に含まれる" do
    create = stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
             .with(body: hash_including("attendees" => [{ "email" => "admin@example.com" }]))
             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token, title: "打合せ", requester: "山田",
                      slot: valid_slot
    expect(last_response.status).to eq(302)
    expect(create).to have_been_requested
  end

  it "不正なメールアドレスは 400" do
    post "/schedule", authenticity_token: csrf_token, token: token, title: "t", requester: "r",
                      slot: valid_slot, attendees: "not-an-email"
    expect(last_response.status).to eq(400)
  end

  it "制御文字を含むメールアドレスは 400" do
    post "/schedule", authenticity_token: csrf_token, token: token, title: "t", requester: "r",
                      slot: valid_slot, attendees: "a\u0000b@example.com"
    expect(last_response.status).to eq(400)
  end

  it "既定（チェックなし）では sendUpdates=none で登録する（招待メールを送らない・回帰）" do
    create = stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
             .with(query: hash_including("sendUpdates" => "none"))
             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token, title: "打合せ", requester: "山田",
                      slot: valid_slot, attendees: "a@example.com"
    expect(last_response.status).to eq(302)
    expect(create).to have_been_requested
  end

  it "「参加者に招待メールを送る」をチェックすると sendUpdates=all で登録する" do
    create = stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
             .with(query: hash_including("sendUpdates" => "all"))
             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token, title: "打合せ", requester: "山田",
                      slot: valid_slot, attendees: "a@example.com", send_invites: "1"
    expect(last_response.status).to eq(302)
    expect(create).to have_been_requested
  end

  it "チェック値が「1」以外の任意文字列なら sendUpdates=none のまま（true 扱いしない）" do
    create = stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
             .with(query: hash_including("sendUpdates" => "none"))
             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token, title: "打合せ", requester: "山田",
                      slot: valid_slot, attendees: "a@example.com", send_invites: "true"
    expect(last_response.status).to eq(302)
    expect(create).to have_been_requested
  end

  it "既定（チェックなし）ではイベントに visibility を付けない（Google の既定に委ねる・回帰）" do
    stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token, title: "打合せ", requester: "山田",
                      slot: valid_slot
    expect(last_response.status).to eq(302)
    expect(a_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .with { |req| !JSON.parse(req.body).key?("visibility") }).to have_been_made
  end

  it "「予定を非公開にする」をチェックすると visibility=private で登録する" do
    create = stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
             .with(body: hash_including("visibility" => "private"))
             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token, title: "打合せ", requester: "山田",
                      slot: valid_slot, private_event: "1"
    expect(last_response.status).to eq(302)
    expect(create).to have_been_requested
  end

  it "非公開のチェック値が「1」以外の任意文字列なら visibility を付けない（true 扱いしない）" do
    stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token, title: "打合せ", requester: "山田",
                      slot: valid_slot, private_event: "true"
    expect(last_response.status).to eq(302)
    expect(a_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .with { |req| !JSON.parse(req.body).key?("visibility") }).to have_been_made
  end

  it "ビデオ会議 URL を説明欄に登録する" do
    create = stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
             .with(body: hash_including("description" => "依頼者: 山田\nビデオ会議: https://zoom.us/j/1"))
             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token, title: "打合せ", requester: "山田",
                      slot: valid_slot, video_url: "https://zoom.us/j/1"
    expect(last_response.status).to eq(302)
    expect(create).to have_been_requested
  end

  it "http/https でないビデオ会議 URL は 400" do
    post "/schedule", authenticity_token: csrf_token, token: token, title: "t", requester: "r",
                      slot: valid_slot, video_url: "javascript:alert(1)"
    expect(last_response.status).to eq(400)
  end

  it "ビデオ会議 URL と Meet 発行の同時指定は 400" do
    post "/schedule", authenticity_token: csrf_token, token: token, title: "t", requester: "r",
                      slot: valid_slot, video_url: "https://zoom.us/j/1", request_meet: "1"
    expect(last_response.status).to eq(400)
  end

  it "Meet 発行時はリンクを発行し、完了画面（本人セッション）に表示する" do
    stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .with(query: hash_including("conferenceDataVersion" => "1"))
      .to_return(status: 200, body: { "hangoutLink" => "https://meet.google.com/abc-defg-hij" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token, title: "打合せ", requester: "山田",
                      slot: valid_slot, request_meet: "1"
    expect(last_response.status).to eq(302)

    get "/t/#{token}"
    expect(last_response.body).to include("https://meet.google.com/abc-defg-hij")
  end

  it "別セッション（漏えいURL想定）では使用済み URL に会議リンクを再表示しない" do
    stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .with(query: hash_including("conferenceDataVersion" => "1"))
      .to_return(status: 200, body: { "hangoutLink" => "https://meet.google.com/abc-defg-hij" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, token: token, title: "打合せ", requester: "山田",
                      slot: valid_slot, request_meet: "1"
    expect(last_response.status).to eq(302)

    clear_cookies # 登録者とは別のセッション（URL だけ知っている第三者）を模す
    get "/t/#{token}"
    expect(last_response.status).to eq(410)
    expect(last_response.body).to include("完了")
    expect(last_response.body).not_to include("meet.google.com")
  end

  # Slack 通知はテスト環境では既定で無効（configure しない）。通知テストのときだけ configure する。
  context "Slack 通知" do
    let(:webhook) { "https://hooks.slack.com/services/T00/B00/xxxx" }

    before do
      SlackNotifier.configure(webhook)
      stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    end
    after { SlackNotifier.configure(nil) } # テスト既定（no-op）へ戻す

    it "予約完了時に依頼者名・日時を含む text を webhook へ POST する" do
      stub_request(:post, webhook).to_return(status: 200, body: "ok")
      post "/schedule", authenticity_token: csrf_token, token: token,
                        title: "打合せ", requester: "山田", slot: valid_slot
      expect(last_response.status).to eq(302)
      expect(
        a_request(:post, webhook).with do |req|
          text = JSON.parse(req.body)["text"]
          text.include?("新規のスケジュールが追加されました") && text.include?("山田") && text.include?("打合せ") &&
            text.match?(%r{\d{1,2}/\d{1,2}（.）\s\d{2}:\d{2}〜\d{2}:\d{2}})
        end
      ).to have_been_made
    end

    it "通知先が 500 を返しても予約自体は成功する（通知はベストエフォート）" do
      stub_request(:post, webhook).to_return(status: 500, body: "error")
      post "/schedule", authenticity_token: csrf_token, token: token,
                        title: "打合せ", requester: "山田", slot: valid_slot
      expect(last_response.status).to eq(302)
      expect(TicketStore.status(TicketStore.find(token))).to eq("used")
    end
  end
end
