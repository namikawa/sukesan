# frozen_string_literal: true

RSpec.describe "管理者トップ GET /admin" do
  it "ログイン後は各ツールへの導線を表示する" do
    login_admin!
    get "/admin"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include('href="/tickets"')
    expect(last_response.body).to include('href="/sync"')
  end
end
