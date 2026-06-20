# frozen_string_literal: true

RSpec.describe "CSRF 保護" do
  it "トークン無しの POST /settings/logout は 403" do
    post "/settings/logout"
    expect(last_response.status).to eq(403)
  end

  it "トークン無しの POST /schedule は 403" do
    post "/schedule", title: "t", requester: "r", slot: "x/y"
    expect(last_response.status).to eq(403)
  end

  it "トークン付きなら 403 にはならない" do
    post "/settings/logout", authenticity_token: csrf_token
    expect(last_response.status).not_to eq(403)
  end
end
