# frozen_string_literal: true

RSpec.describe "OAuth トークン更新失敗時のフォールバック" do
  # 期限切れ＋refresh_token あり → アクセス時に refresh が走る状態。
  let(:expired_google) { { "access_token" => "stale", "refresh_token" => "rt", "expires_at" => 1 } }
  let(:valid_microsoft) { { "access_token" => "ms-token", "expires_at" => 4_102_444_800 } }
  let(:settings) do
    {
      "business_start" => "09:00", "business_end" => "18:00", "business_days" => [1, 2, 3, 4, 5],
      "lunch_start" => "11:00", "lunch_end" => "14:00", "lunch_minutes" => 60, "sync_window_days" => 30
    }
  end

  before do
    allow(TokenStore).to receive(:load).and_return(expired_google)
    allow(TokenStore).to receive(:load).with(:microsoft).and_return(valid_microsoft)
    allow(TokenStore).to receive(:with_lock).and_yield
    allow(SettingsStore).to receive(:load).and_return(settings)
    allow(SettingsStore).to receive(:save)
    # refresh は恒久失効（invalid_grant）で失敗する。
    stub_request(:post, "https://oauth2.googleapis.com/token")
      .to_return(status: 400, headers: { "Content-Type" => "application/json" },
                 body: '{"error":"invalid_grant"}')
  end

  it "公開ページの検索は 500 にせず案内を表示する" do
    token = TicketStore.create
    expect do
      get "/t/#{token}", start_date: "2099-01-04", end_date: "2099-01-04", duration: "30"
    end.to output(/\[oauth\] トークン更新失敗 \(provider=google\): OAuth2::Error/).to_stderr
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("連携に問題があるため検索できません")
  end

  it "予約登録は 502 と案内を返し、チケットを消費しない" do
    token = TicketStore.create
    slot = "2099-01-04T10:00:00+09:00/2099-01-04T10:30:00+09:00"
    expect do
      post "/schedule", authenticity_token: csrf_token, token: token,
                        title: "打合せ", requester: "山田", slot: slot
    end.to output(/\[oauth\]/).to_stderr
    expect(last_response.status).to eq(502)
    expect(last_response.body).to include("連携に問題があるため登録できません")
    expect(TicketStore.status(TicketStore.find(token))).to eq("active")
  end

  it "同期チェック結果の表示は 500 にせず「該当なし」と誤認させない形で再連携を促す" do
    login_admin!
    post "/check", authenticity_token: csrf_token, range_mode: "days", sync_window_days: "7"
    expect(last_response.status).to eq(302)

    expect { get "/sync" }.to output(/\[oauth\]/).to_stderr
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("連携の更新に失敗しました")
    expect(last_response.body).not_to include("同期の必要はありません")
  end

  it "同期の反映（POST /sync）は反映せず再連携を促す" do
    login_admin!
    post "/check", authenticity_token: csrf_token, range_mode: "days", sync_window_days: "7"
    expect { post "/sync", authenticity_token: csrf_token, selected: ["x"] }
      .to output(/\[oauth\]/).to_stderr
    expect(last_response.status).to eq(302)

    get "/sync" # flash の表示先
    expect(last_response.body).to include("連携の更新に失敗しました")
  end
end
