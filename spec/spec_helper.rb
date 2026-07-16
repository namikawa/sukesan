# frozen_string_literal: true

require "time"
require "fileutils"
require "bcrypt"

# テスト用の環境設定（app / dotenv 読み込みより前に確定させる）。
ENV["APP_ENV"] ||= "test"
ENV["TZ"] = "Asia/Tokyo" # スロットの +09:00 と Time.local を一致させ、テストを決定的にする
ENV["ADMIN_PASSWORD"] = "test-admin-password" # テストでログインに送信する平文
# OAuth クライアントを生成可能にする（HTTP は WebMock でスタブするため値はダミーで可）。
# .env に依存せず CI でも自己完結させるため、未設定ならダミーを入れる。
ENV["GOOGLE_CLIENT_ID"] ||= "test-google-client-id"
ENV["GOOGLE_CLIENT_SECRET"] ||= "test-google-client-secret"
ENV["MS_CLIENT_ID"] ||= "test-ms-client-id"
ENV["MS_CLIENT_SECRET"] ||= "test-ms-client-secret"
# bcrypt のコストを最小化してテストを高速化し、平文からダイジェストを生成して app に渡す。
BCrypt::Engine.cost = BCrypt::Engine::MIN_COST
ENV["ADMIN_PASSWORD_DIGEST"] = BCrypt::Password.create(ENV.fetch("ADMIN_PASSWORD"))
ENV["SESSION_SECRET"] ||= "0123456789abcdef" * 4 # Rack::Session::Cookie は 64 文字以上必須
# チケットの永続先を一時ディレクトリに隔離し、実データ（data/tickets）を汚さない。
ENV["TICKETS_DIR"] ||= File.expand_path("../tmp/test-tickets", __dir__)

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
  # チケットの永続ファイルもテストごとに消し、状態が漏れないようにする。
  config.before(:each, type: :request) do
    SCHEDULE_LIMITER.reset!
    SEARCH_LIMITER.reset!
    LOGIN_LIMITER.reset!
    API_LIMITER.reset!
    FileUtils.rm_rf(ENV.fetch("TICKETS_DIR"))
  end
end
