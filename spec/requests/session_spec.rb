# frozen_string_literal: true

require "rack/session/encryptor"

RSpec.describe "セッション Cookie" do
  it "ペイロードは JSON で直列化される（Marshal を使わない）" do
    get "/settings" # ログインフォーム描画で CSRF トークンがセッションへ書かれる
    cookie = last_response.headers["Set-Cookie"][/sukesan\.session\.v2=([^;]+)/, 1]
    expect(cookie).not_to be_nil

    # アプリと同じ鍵・purpose・serialize_json 設定で復号できること＝JSON 直列化の確認。
    # Marshal に戻ると JSON::ParserError で fail する（セキュリティ設定の回帰網）。
    encryptor = Rack::Session::Encryptor.new(
      ENV.fetch("SESSION_SECRET"), purpose: "sukesan.session.v2", serialize_json: true
    )
    data = encryptor.decrypt(Rack::Utils.unescape(cookie))
    expect(data).to be_a(Hash)
  end
end
