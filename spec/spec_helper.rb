# frozen_string_literal: true

require "time"

# テスト用の環境設定（app / dotenv 読み込みより前に確定させる）。
ENV["APP_ENV"] ||= "test"
ENV["TZ"] = "Asia/Tokyo" # スロットの +09:00 と Time.local を一致させ、テストを決定的にする
ENV["ADMIN_PASSWORD"] = "test-admin-password"
ENV["SESSION_SECRET"] ||= "test-session-secret-0123456789"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "event"
require "event_differ"
require "free_slot_finder"
require "rate_limiter"
require "token_cipher"

require "rack/test"
require "webmock/rspec"
require_relative "../app"

# リクエストスペック用のヘルパ（Sinatra アプリを直接叩く）。
module RequestHelpers
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  # 直近に描画されたフォームから CSRF トークンを取り出す（ログイン画面を利用）。
  def csrf_token
    get "/settings"
    last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
  end

  def login_admin!
    post "/settings/login", authenticity_token: csrf_token, password: ENV.fetch("ADMIN_PASSWORD")
  end
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!

  config.define_derived_metadata(file_path: %r{/spec/requests/}) do |meta|
    meta[:type] = :request
  end
  config.include RequestHelpers, type: :request

  # レート制限はプロセス内メモリのため、リクエストスペック間でリセットする。
  config.before(:each, type: :request) do
    SCHEDULE_LIMITER.reset!
    LOGIN_LIMITER.reset!
  end
end
