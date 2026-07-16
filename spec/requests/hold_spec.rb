# frozen_string_literal: true

RSpec.describe "複数カレンダー仮押さえ /hold" do
  let(:token_hash) { { "access_token" => "fake", "expires_at" => 4_102_444_800, "admin_email" => "admin@example.com" } }
  let(:settings) do
    {
      "business_start" => "09:00", "business_end" => "18:00", "business_days" => [1, 2, 3, 4, 5],
      "lunch_start" => "11:00", "lunch_end" => "14:00", "lunch_minutes" => 60
    }
  end

  # 過去・直前拒否（リードタイム）に掛からない、十分先の営業日（週末・祝日を避ける）。
  let(:date) { future_business_day }
  let(:slot1) { "#{date}T09:00:00+09:00/#{date}T09:30:00+09:00" }
  let(:slot2) { "#{date}T10:00:00+09:00/#{date}T10:30:00+09:00" }
  let(:ticket) { TicketStore.create }

  before do
    allow(TokenStore).to receive(:load).and_return(token_hash)
    allow(SettingsStore).to receive(:load).and_return(settings)
    stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    stub_request(:patch, %r{googleapis\.com/calendar/v3/calendars/primary/events/})
      .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    stub_request(:delete, %r{googleapis\.com/calendar/v3/calendars/primary/events/})
      .to_return(status: 204, body: "")
  end

  def create_holds(slots: [slot1, slot2], **extra)
    post "/hold", authenticity_token: csrf_token, token: ticket,
                  requester: "山田", title: "打合せ", slots: slots, **extra
  end

  it "選択した日程を [仮ブロック] として作成し、チケットを仮押さえ状態にする" do
    allow(AuditLog).to receive(:record)
    create_holds
    expect(last_response.status).to eq(302)

    expect(TicketStore.status(TicketStore.find(ticket))).to eq("held")
    created = a_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
              .with { |req| JSON.parse(req.body)["summary"].start_with?("[仮ブロック] 打合せ - 山田") }
    expect(created).to have_been_made.times(2)
    expect(AuditLog).to have_received(:record)
      .with(:hold_created, ip: anything, target: a_string_matching(/count=2\z/))

    follow_redirect!
    expect(last_response.body).to include("仮押さえ中の日程")
    expect(last_response.body).to include("この日程で決定する")
  end

  it "調整画面（検索結果）に仮押さえタブが表示される" do
    get "/t/#{ticket}", start_date: date.to_s, end_date: date.to_s, duration: "30"
    expect(last_response.body).to include("複数スケジュール仮押さえ")
    expect(last_response.body).to include('name="slots[]"')
  end

  it "仮押さえ後はセッション Cookie の期限が 7 日へ延長され、通常セッションは 24 時間のまま" do
    get "/settings" # 通常セッション（CSRF トークンのみ）
    normal = last_response.headers["Set-Cookie"][/expires=([^;]+)/i, 1]
    expect(Time.parse(normal)).to be < Time.now + (2 * 86_400)

    create_holds
    extended = last_response.headers["Set-Cookie"][/expires=([^;]+)/i, 1]
    expect(Time.parse(extended)).to be > Time.now + (6 * 86_400)
  end

  it "別ブラウザ（Cookie 無し）には内容を表示せず、決定・削除は 403" do
    create_holds
    clear_cookies # 別ブラウザを模す

    get "/t/#{ticket}"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("仮押さえを行ったブラウザからのみ")
    expect(last_response.body).not_to include("この日程で決定する")
    # 予定名・依頼者・日程の一覧も表示しない。
    expect(last_response.body).not_to include("打合せ")
    expect(last_response.body).not_to include("山田")
    expect(last_response.body).not_to include("09:00")

    post "/hold/confirm", authenticity_token: csrf_token, token: ticket, slot: "#{date}T09:00:00+09:00"
    expect(last_response.status).to eq(403)

    post "/hold/delete", authenticity_token: csrf_token, token: ticket, slot: "#{date}T09:00:00+09:00"
    expect(last_response.status).to eq(403)
  end

  it "ホルダーは 1 件に決定でき、決定イベントは件名更新・他候補は削除される" do
    create_holds
    post "/hold/confirm", authenticity_token: csrf_token, token: ticket,
                          slot: "#{date}T09:00:00+09:00"
    expect(last_response.status).to eq(302)

    saved = TicketStore.find(ticket)
    expect(TicketStore.status(saved)).to eq("used")
    expect(saved["slot_start"]).to eq("#{date}T09:00:00+09:00")

    patched = a_request(:patch, %r{googleapis\.com/calendar/v3/calendars/primary/events/})
              .with { |req| JSON.parse(req.body)["summary"] == "打合せ - 山田 (from 調整ツール)" }
    expect(patched).to have_been_made.once
    expect(a_request(:delete, %r{googleapis\.com/calendar/v3/calendars/primary/events/}))
      .to have_been_made.once

    follow_redirect!
    expect(last_response.status).to eq(410) # used の案内ページ
    expect(last_response.body).to include("決定しました")
  end

  it "決定時に「参加者に招待メールを送る」をチェックすると sendUpdates=all で更新する" do
    create_holds
    post "/hold/confirm", authenticity_token: csrf_token, token: ticket,
                          slot: "#{date}T09:00:00+09:00", attendees: "a@example.com", send_invites: "1"
    expect(last_response.status).to eq(302)
    expect(TicketStore.status(TicketStore.find(ticket))).to eq("used")
    expect(a_request(:patch, %r{googleapis\.com/calendar/v3/calendars/primary/events/})
      .with(query: hash_including("sendUpdates" => "all"))).to have_been_made.once
  end

  it "決定時にチェックが無ければ従来どおり sendUpdates=none で更新する（回帰）" do
    create_holds
    post "/hold/confirm", authenticity_token: csrf_token, token: ticket,
                          slot: "#{date}T09:00:00+09:00", attendees: "a@example.com"
    expect(last_response.status).to eq(302)
    expect(a_request(:patch, %r{googleapis\.com/calendar/v3/calendars/primary/events/})
      .with(query: hash_including("sendUpdates" => "none"))).to have_been_made.once
  end

  it "「予定を非公開にする」で仮押さえすると [仮ブロック] 全件を visibility=private で作成する" do
    create_holds(private_event: "1")
    expect(last_response.status).to eq(302)
    expect(TicketStore.status(TicketStore.find(ticket))).to eq("held")
    expect(a_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .with(body: hash_including("visibility" => "private"))).to have_been_made.times(2)
  end

  it "チェックなしの仮押さえは visibility を付けない（Google の既定に委ねる・回帰）" do
    create_holds
    expect(last_response.status).to eq(302)
    expect(a_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .with { |req| !JSON.parse(req.body).key?("visibility") }).to have_been_made.times(2)
  end

  it "非公開で仮押さえ→決定の patch は visibility に触れない（作成時の指定が維持される）" do
    create_holds(private_event: "1")
    post "/hold/confirm", authenticity_token: csrf_token, token: ticket, slot: "#{date}T09:00:00+09:00"
    expect(last_response.status).to eq(302)
    expect(TicketStore.status(TicketStore.find(ticket))).to eq("used")
    expect(a_request(:patch, %r{googleapis\.com/calendar/v3/calendars/primary/events/})
      .with { |req| !JSON.parse(req.body).key?("visibility") }).to have_been_made.once
  end

  it "holds に無いスロットでは決定できず、決定画面に警告を表示する" do
    create_holds
    post "/hold/confirm", authenticity_token: csrf_token, token: ticket, slot: "#{date}T13:00:00+09:00"
    expect(last_response.status).to eq(302)

    follow_redirect!
    expect(last_response.body).to include("決定する日程を選択してください")
    expect(TicketStore.status(TicketStore.find(ticket))).to eq("held") # 決定されていない
  end

  it "個別削除で候補が減り、最後の 1 件を削除すると終了（cancelled）する" do
    create_holds
    post "/hold/delete", authenticity_token: csrf_token, token: ticket, slot: "#{date}T09:00:00+09:00"
    expect(last_response.status).to eq(302)
    expect(TicketStore.status(TicketStore.find(ticket))).to eq("held")

    post "/hold/delete", authenticity_token: csrf_token, token: ticket, slot: "#{date}T10:00:00+09:00"
    expect(TicketStore.status(TicketStore.find(ticket))).to eq("cancelled")

    get "/t/#{ticket}"
    expect(last_response.status).to eq(410)
    expect(last_response.body).to include("取りやめられ")
  end

  it "「すべて削除して終了」で全イベントを削除して cancelled にする" do
    create_holds
    post "/hold/cancel", authenticity_token: csrf_token, token: ticket
    expect(last_response.status).to eq(302)
    expect(TicketStore.status(TicketStore.find(ticket))).to eq("cancelled")
    expect(a_request(:delete, %r{googleapis\.com/calendar/v3/calendars/primary/events/}))
      .to have_been_made.times(2)
  end

  it "入力エラー後も依頼者名・予定名・非公開チェック・選択済みスロットを復元し、仮押さえタブを初期表示にする" do
    six = (0...6).map do |i|
      "#{date}T#{format('%02d', 9 + i)}:00:00+09:00/#{date}T#{format('%02d', 9 + i)}:30:00+09:00"
    end
    post "/hold", authenticity_token: csrf_token, token: ticket, requester: "山田", title: "打合せ",
                  slots: six, private_event: "1", start_date: date.to_s, end_date: date.to_s, duration: "30"
    follow_redirect!

    expect(last_response.body).to include('value="山田"')
    expect(last_response.body).to include('value="打合せ"')
    expect(last_response.body).to match(/name="private_event" value="1" checked/)
    expect(last_response.body).to match(/value="#{Regexp.escape(six.first)}" checked/)
    expect(last_response.body).to include('class="is-active" data-tab="tab-hold"')
  end

  it "件数超過・重複・候補外の選択は弾き、元画面上部に警告を表示する" do
    six = (0...6).map do |i|
      "#{date}T#{format('%02d', 9 + i)}:00:00+09:00/#{date}T#{format('%02d', 9 + i)}:30:00+09:00"
    end
    create_holds(slots: six)
    expect(last_response.status).to eq(302) # 最大 5 件
    follow_redirect!
    expect(last_response.body).to include("仮押さえは最大 5 件までです")

    create_holds(slots: [slot1, slot1])
    follow_redirect! # 時間帯の重複
    expect(last_response.body).to include("重複しています")

    create_holds(slots: ["#{date}T09:15:00+09:00/#{date}T09:45:00+09:00"])
    follow_redirect! # サーバ側再計算の候補に無い枠
    expect(last_response.body).to include("予約できなくなりました")
    expect(TicketStore.status(TicketStore.find(ticket))).to eq("active") # 仮押さえされていない
  end

  it "使用済みチケットでは仮押さえできず、案内ページに警告を表示する" do
    TicketStore.use!(ticket, attrs: {})
    create_holds
    expect(last_response.status).to eq(302)

    follow_redirect!
    expect(last_response.status).to eq(410)
    expect(last_response.body).to include("この URL は無効か、期限切れです")
  end

  # Cookie 溢れ（セッション全損）対策の回帰。
  # 最大長の任意項目（参加者・URL）で決定エラーを起こすと form_restore が session に載る。上限（cap）が無いと
  # session が 4096 バイトを超え、Rack::Session::Cookie は Set-Cookie を丸ごと落とす（＝flash_alert・holder_keys
  # まで含む session 全損。Set-Cookie が空になる）。cap により form_restore は保存されず、session は
  # 「書き込み可能（非空）かつ 4096 バイト未満」に保たれる。この両側（非空・上限内）を検証する。
  describe "セッション Cookie の肥大化対策" do
    def set_cookie_size = last_response.headers["Set-Cookie"].to_s.bytesize

    it "最大長入力の決定エラーでも Set-Cookie は非空かつ 4096 バイト未満（session 全損しない）" do
      allow(AuditLog).to receive(:record)

      # 仮押さえで held 状態にし、holder_key を session に載せる。
      create_holds(slots: [slot1])
      expect(last_response.status).to eq(302)

      # 最大長の任意項目（attendees は保存上限 2000・video_url は MAX_URL_LENGTH=2048）で決定エラーを起こす。
      SCHEDULE_LIMITER.reset!
      attendees = "a@example.com," * 200 # 2800 文字（アプリ側で [0, 2000] に切り詰め）
      video_url = "https://example.com/#{'a' * 2100}" # MAX_URL_LENGTH 超（同様に切り詰め）
      post "/hold/confirm", authenticity_token: csrf_token, token: ticket,
                            slot: "#{date}T23:00:00+09:00", attendees: attendees, video_url: video_url

      expect(last_response.status).to eq(302)
      expect(set_cookie_size).to be_positive # session が丸ごと落ちていない（cap が無いと 0 になる）
      expect(set_cookie_size).to be < 4096
    end
  end
end
