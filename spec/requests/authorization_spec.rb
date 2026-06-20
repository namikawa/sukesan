# frozen_string_literal: true

RSpec.describe "認可境界" do
  it "未ログインで GET /sync は /admin へリダイレクトする" do
    get "/sync"
    expect(last_response.status).to eq(302)
    expect(last_response.headers["Location"]).to end_with("/admin")
  end

  it "未ログインで GET /auth/google は /admin へリダイレクトする" do
    get "/auth/google"
    expect(last_response.status).to eq(302)
    expect(last_response.headers["Location"]).to end_with("/admin")
  end

  it "未ログインの POST /settings は（CSRF 通過後）/admin へリダイレクトする" do
    post "/settings", authenticity_token: csrf_token, business_start: "09:00", business_end: "18:00"
    expect(last_response.status).to eq(302)
    expect(last_response.headers["Location"]).to end_with("/admin")
  end

  it "未ログインの POST /check は /admin へリダイレクトする" do
    post "/check", authenticity_token: csrf_token
    expect(last_response.status).to eq(302)
    expect(last_response.headers["Location"]).to end_with("/admin")
  end

  it "ログイン後は GET /sync が 200 を返す" do
    login_admin!
    get "/sync"
    expect(last_response.status).to eq(200)
  end
end
