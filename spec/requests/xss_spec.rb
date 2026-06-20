# frozen_string_literal: true

RSpec.describe "XSS（出力の自動エスケープ）" do
  let(:settings) do
    {
      "business_start" => "09:00", "business_end" => "18:00", "business_days" => [1, 2, 3, 4, 5],
      "lunch_start" => "11:00", "lunch_end" => "14:00", "lunch_minutes" => 60
    }
  end

  before do
    # Google 連携済みにして調整画面にフォームを描画させる（API 呼び出しは発生しない範囲で検証）。
    allow(TokenStore).to receive(:load).and_return({ "access_token" => "fake", "expires_at" => 4_102_444_800 })
    allow(SettingsStore).to receive(:load).and_return(settings)
  end

  it "クエリの start_date がエスケープされて出力される" do
    token = TicketStore.create
    get "/t/#{token}", start_date: '"><script>alert(1)</script>'
    expect(last_response.body).not_to include('"><script>alert(1)</script>')
    expect(last_response.body).to include("&lt;script&gt;")
  end
end
