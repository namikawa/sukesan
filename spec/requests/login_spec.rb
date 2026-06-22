# frozen_string_literal: true

RSpec.describe "管理者ログイン" do
  it "CSRF トークンが無いと 403" do
    post "/settings/login", password: ENV.fetch("ADMIN_PASSWORD")
    expect(last_response.status).to eq(403)
  end

  it "誤ったパスワードでは管理者にならない" do
    post "/settings/login", authenticity_token: csrf_token, password: "wrong"
    get "/settings"
    expect(last_response.body).to include("管理者ログイン")
  end

  it "正しいパスワードで管理者になる" do
    login_admin!
    get "/settings"
    expect(last_response.body).to include("<h1>設定</h1>")
  end

  it "規定回数を超えると 429 を返す" do
    token = csrf_token
    statuses = Array.new(12) do
      post "/settings/login", authenticity_token: token, password: "wrong"
      last_response.status
    end
    expect(statuses).to include(429)
  end
end
