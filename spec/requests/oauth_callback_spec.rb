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
end
