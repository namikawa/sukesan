# frozen_string_literal: true

require "time"
require_relative "support/test_environment"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "event"
require "event_differ"
require "free_slot_finder"
require "rate_limiter"
require "token_cipher"

require "rack/test"
require "webmock/rspec"
require_relative "../app"

# 複数のスペックで共有する shared_context（.rspec は spec_helper のみ require するためここで読み込む）。
require_relative "support/api_request_context"

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

  # 予約が成立する十分先の営業日（週末に加え祝日も避ける）。実行日に依存させず、
  # 実行日の翌営業日がたまたま祝日でも suite が落ちないようにする（祝日除外の回帰対策）。
  # 判定は本番と同じ AvailabilitySearch.business_day? を再利用する。
  def future_business_day(from: Date.today + 7, business_days: [1, 2, 3, 4, 5])
    d = from
    d += 1 until AvailabilitySearch.business_day?(d, business_days)
    d
  end
end

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!

  config.define_derived_metadata(file_path: %r{/spec/requests/}) do |meta|
    meta[:type] = :request
  end
  config.include RequestHelpers, type: :request

  # Firestore アダプタのテストはエミュレータ（FIRESTORE_EMULATOR_HOST）がある時だけ実行する。
  config.filter_run_excluding(:firestore) unless ENV["FIRESTORE_EMULATOR_HOST"]

  # レート制限はプロセス内メモリのため、リクエストスペック間でリセットする。
  # チケット・OAuth トークン・設定もテストごとに消し、状態が漏れないようにする。
  config.before(:each, type: :request) do
    SCHEDULE_LIMITER.reset!
    SEARCH_LIMITER.reset!
    LOGIN_LIMITER.reset!
    API_LIMITER.reset!
    API_WRITE_LIMITER.reset!
    TestEnvironment.reset!
  end
end
