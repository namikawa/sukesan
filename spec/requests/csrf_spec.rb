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

  it "/api/ 配下の POST は CSRF 検証の対象外（Bearer 認証のみでセッション Cookie を使わないため）" do
    # 発行済みキーが無い＝API 自体が存在しない扱いの 404（JSON）まで到達する。
    # CSRF ミドルウェアで弾かれていれば、その手前で 403（text/plain の Forbidden）になる。
    allow(SettingsStore).to receive(:load).and_return(SettingsStore::DEFAULT.dup)
    post "/api/v1/tickets"
    expect(last_response.status).to eq(404)
    expect(JSON.parse(last_response.body).dig("error", "code")).to eq("not_found")
  end

  it "/api で始まるだけの別パスは除外に含めない（除外は /api/ の前方一致のみ）" do
    post "/apikeys"
    expect(last_response.status).to eq(403)
  end

  it "/api/ から抜け出すパス（../・エンコード済み）で除外を悪用できない" do
    post "/api/../settings/logout"
    expect(last_response.status).to eq(403)

    post "/api/..%2fsettings/logout"
    expect(last_response.status).to eq(403)
  end
end
