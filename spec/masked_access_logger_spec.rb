# frozen_string_literal: true

require "stringio"
require "rack/mock_request"

RSpec.describe MaskedAccessLogger do
  let(:io) { StringIO.new }
  let(:app) { ->(_env) { [200, { "content-length" => "3" }, ["ok\n"]] } }
  let(:logger) { described_class.new(app, io, "test-hmac-key") }

  # CommonLogger はレスポンス body の close 時にログを書くため、明示的に close する。
  def request(url)
    env = Rack::MockRequest.env_for(url)
    _, _, body = logger.call(env)
    body.close
    env
  end

  it "/t/<token> の token を HMAC 短縮 ID に置換し、生値を残さない" do
    request("/t/secret-token-value?start_date=2026-07-04")
    expect(io.string).not_to include("secret-token-value")
    expect(io.string).to match(%r{/t/~[0-9a-f]{8}\?start_date=2026-07-04})
  end

  it "同じ token は同じ短縮 ID になる（相関可能）" do
    request("/t/same-token")
    request("/t/same-token")
    ids = io.string.scan(%r{/t/(~[0-9a-f]{8})})
    expect(ids.size).to eq(2)
    expect(ids.uniq.size).to eq(1)
  end

  it "OAuth callback のクエリ（code/state）を [FILTERED] に置換する" do
    request("/auth/google/callback?code=auth-code-value&state=state-value")
    expect(io.string).not_to include("auth-code-value")
    expect(io.string).to include("/auth/google/callback?[FILTERED]")
  end

  it "その他のパス・クエリはそのまま出力する" do
    request("/tickets?page=2")
    expect(io.string).to include("/tickets?page=2")
  end

  it "実リクエストの env は書き換えない（マスクはログ出力にだけ効く）" do
    env = request("/t/secret-token-value")
    expect(env["PATH_INFO"]).to eq("/t/secret-token-value")
  end
end
