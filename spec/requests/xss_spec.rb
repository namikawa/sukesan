# frozen_string_literal: true

RSpec.describe "XSS（出力の自動エスケープ）" do
  before do
    # Google 連携済みにしてトップにフォームを描画させる（API 呼び出しは発生しない範囲で検証）。
    allow(TokenStore).to receive(:load).and_return({ "access_token" => "fake", "expires_at" => 4_102_444_800 })
  end

  it "クエリの start_date がエスケープされて出力される" do
    get "/", start_date: '"><script>alert(1)</script>'
    expect(last_response.body).not_to include('"><script>alert(1)</script>')
    expect(last_response.body).to include("&lt;script&gt;")
  end
end
