# frozen_string_literal: true

# レート制限・監査ログに使うクライアント IP（AuthHelpers#client_ip）の判定。
# ログインの失敗回数の制限（LOGIN_LIMITER: 5 分で 10 回）を通して確かめる。
RSpec.describe "クライアント IP の判定" do
  def fail_login(headers = {})
    post "/settings/login", { authenticity_token: @token, password: "wrong" }, headers
    last_response.status
  end

  before { @token = csrf_token }

  context "APP_TRUST_PROXY=true（前段プロキシ 1 段の背後）" do
    around do |example|
      ENV["APP_TRUST_PROXY"] = "true"
      example.run
    ensure
      ENV.delete("APP_TRUST_PROXY")
    end

    it "X-Forwarded-For の前の値や Forwarded ヘッダを変えても、最後の値が同じなら同じ接続元として数える" do
      10.times do |i|
        fail_login("HTTP_X_FORWARDED_FOR" => "198.51.100.#{i}, 203.0.113.7",
                   "HTTP_FORWARDED" => "for=192.0.2.#{i}")
      end

      expect(fail_login("HTTP_X_FORWARDED_FOR" => "198.51.100.99, 203.0.113.7")).to eq(429)
    end

    it "X-Forwarded-For の最後の値が違えば、別の接続元として数える" do
      10.times { fail_login("HTTP_X_FORWARDED_FOR" => "203.0.113.7") }

      expect(fail_login("HTTP_X_FORWARDED_FOR" => "203.0.113.8")).not_to eq(429)
    end

    it "X-Forwarded-For が無ければ REMOTE_ADDR で数える" do
      10.times { fail_login("REMOTE_ADDR" => "10.0.0.5") }

      expect(fail_login("REMOTE_ADDR" => "10.0.0.5")).to eq(429)
      expect(fail_login("REMOTE_ADDR" => "10.0.0.6")).not_to eq(429)
    end

    it "X-Forwarded-For の最後の値が空なら、手前の値ではなく REMOTE_ADDR で数える" do
      10.times { |i| fail_login("REMOTE_ADDR" => "10.0.0.5", "HTTP_X_FORWARDED_FOR" => "198.51.100.#{i},") }

      expect(fail_login("REMOTE_ADDR" => "10.0.0.5")).to eq(429)
      expect(fail_login("REMOTE_ADDR" => "10.0.0.6", "HTTP_X_FORWARDED_FOR" => "198.51.100.0,")).not_to eq(429)
    end
  end

  context "APP_TRUST_PROXY 未設定（直接公開）" do
    it "X-Forwarded-For・Forwarded は見ず、REMOTE_ADDR で数える" do
      10.times do |i|
        fail_login("REMOTE_ADDR" => "10.0.0.5", "HTTP_X_FORWARDED_FOR" => "203.0.113.#{i}",
                   "HTTP_FORWARDED" => "for=192.0.2.#{i}")
      end

      expect(fail_login("REMOTE_ADDR" => "10.0.0.5", "HTTP_X_FORWARDED_FOR" => "203.0.113.99")).to eq(429)
      expect(fail_login("REMOTE_ADDR" => "10.0.0.6", "HTTP_X_FORWARDED_FOR" => "203.0.113.0")).not_to eq(429)
    end
  end
end
