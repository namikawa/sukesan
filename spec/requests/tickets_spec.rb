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
      get "/tickets"
      expect(last_response.body).to include("/t/#{token}")
      expect(last_response.body).to include("copy-btn")
    end
  end

  describe "一覧のページネーション GET /tickets" do
    before { login_admin! }

    # active チケットは各行にコピーボタンを持つため、その数で表示件数を数える。
    def shown_rows = last_response.body.scan("copy-btn").size

    it "既定は 1 ページ 10 件" do
      12.times { TicketStore.create }
      get "/tickets"
      expect(shown_rows).to eq(10)
      expect(last_response.body).to include("12 件中")
      expect(last_response.body).to include("1 / 2 ページ")
    end

    it "per で表示件数を変えられる" do
      25.times { TicketStore.create }
      get "/tickets", per: "20"
      expect(shown_rows).to eq(20)
      expect(last_response.body).to include("1 / 2 ページ")
    end

    it "ホワイトリスト外の per は既定 10 にフォールバックする" do
      12.times { TicketStore.create }
      get "/tickets", per: "13"
      expect(shown_rows).to eq(10)
    end

    it "page で次ページの残りだけを表示する" do
      12.times { TicketStore.create }
      get "/tickets", page: "2"
      expect(shown_rows).to eq(2)
      expect(last_response.body).to include("2 / 2 ページ")
    end

    it "範囲外の page は端にクランプする" do
      12.times { TicketStore.create }
      get "/tickets", page: "99"
      expect(last_response.body).to include("2 / 2 ページ")
      get "/tickets", page: "0"
      expect(last_response.body).to include("1 / 2 ページ")
    end

    it "1 ページに収まるときはページ送りを出さない" do
      5.times { TicketStore.create }
      get "/tickets"
      expect(shown_rows).to eq(5)
      expect(last_response.body).not_to include("ページ送り")
    end
  end

  describe "アクセス GET /t/:token" do
    it "有効なトークンなら調整画面（検索フォーム）を表示する" do
      token = TicketStore.create
      get "/t/#{token}"
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include("action=\"/t/#{token}\"")
      expect(last_response.body).to include("空き時間をチェック")
      expect(last_response.body).to include(APP_TIMEZONE) # タイムゾーン注記
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

    it "空き時間検索が規定回数を超えると 429 を返す" do
      stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
        .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })
      token = TicketStore.create
      query = { start_date: "2026-06-22", end_date: "2026-06-22", duration: "30" }

      statuses = Array.new(25) do
        get "/t/#{token}", query
        last_response.status
      end

      expect(statuses.first).to eq(200) # 最初の検索は通る
      expect(statuses).to include(429)  # 上限超過で 429
    end

    it "パラメータ無しのページ表示はレート制限を消費しない" do
      token = TicketStore.create
      30.times { get "/t/#{token}" }
      expect(last_response.status).to eq(200)
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

  describe "仮押さえ中チケットの管理" do
    let(:held_token) do
      token = TicketStore.create
      TicketStore.hold!(token, attrs: {
                          "requester" => "山田", "title" => "打合せ", "holder_key" => "k",
                          "holds" => [
                            { "event_id" => "sukesanaaa", "slot_start" => "2026-07-10T10:00:00+09:00",
                              "slot_end" => "2026-07-10T10:30:00+09:00" },
                            { "event_id" => "sukesanbbb", "slot_start" => "2026-07-11T14:00:00+09:00",
                              "slot_end" => "2026-07-11T14:30:00+09:00" }
                          ]
                        })
      token
    end

    before do
      allow(TokenStore).to receive(:load)
        .and_return({ "access_token" => "fake", "expires_at" => 4_102_444_800 })
      stub_request(:delete, %r{googleapis\.com/calendar/v3/calendars/primary/events/})
        .to_return(status: 204, body: "")
    end

    it "一覧に「仮押さえ中」と残件数・日程を表示する" do
      held_token
      login_admin!
      get "/tickets"
      expect(last_response.body).to include("仮押さえ中")
      expect(last_response.body).to include("仮押さえ 残 2 件")
      expect(last_response.body).to include("2026-07-10 10:00")
      expect(last_response.body).to include("2026-07-11 14:00")
      expect(last_response.body).not_to include("不明")
    end

    it "無効化すると残りの仮押さえイベントも削除する（kill switch）" do
      login_admin!
      post "/tickets/#{held_token}/revoke", authenticity_token: csrf_token

      expect(TicketStore.status(TicketStore.find(held_token))).to eq("revoked")
      expect(a_request(:delete, %r{googleapis\.com/calendar/v3/calendars/primary/events/}))
        .to have_been_made.times(2)
    end
  end
end
