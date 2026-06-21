# frozen_string_literal: true

RSpec.describe "OAuth コールバック異常系" do
  before { login_admin! }

  it "state が無いと 400" do
    get "/auth/google/callback", code: "abc"
    expect(last_response.status).to eq(400)
  end

  it "state が不一致だと 400" do
    get "/auth/google" # セッションに state を発行
    get "/auth/google/callback", state: "WRONG", code: "abc"
    expect(last_response.status).to eq(400)
  end

  it "state が一致しても code が無ければ 400" do
    get "/auth/google"
    state = last_response.headers["Location"][/[?&]state=([^&]+)/, 1]
    get "/auth/google/callback", state: state
    expect(last_response.status).to eq(400)
  end

  it "連携成功時に userinfo から主催者メールを取得して保存する" do
    get "/auth/google"
    state = last_response.headers["Location"][/[?&]state=([^&]+)/, 1]

    stub_request(:post, "https://oauth2.googleapis.com/token")
      .to_return(status: 200,
                 body: { access_token: "at", refresh_token: "rt", expires_in: 3600 }.to_json,
                 headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo")
      .to_return(status: 200, body: { email: "owner@example.com" }.to_json,
                 headers: { "Content-Type" => "application/json" })
    allow(TokenStore).to receive(:save) # 実ファイルへの書き込みを避ける

    get "/auth/google/callback", state: state, code: "abc"

    expect(last_response.status).to eq(302)
    expect(TokenStore).to have_received(:save).with(hash_including("admin_email" => "owner@example.com"))
  end
end
