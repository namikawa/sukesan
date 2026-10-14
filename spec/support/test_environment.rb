# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "bcrypt"
require "dotenv"
require_relative "../../lib/stores/file_token_store"
require_relative "../../lib/stores/file_settings_store"

# app / dotenv/load より先に読み込み、本番の環境変数と永続ファイルからテストを隔離する。
module TestEnvironment
  ROOT = Dir.mktmpdir("sukesan-spec-")
  TICKETS_DIR = File.join(ROOT, "tickets")
  SETTINGS_PATH = File.join(ROOT, "settings.json")
  TOKEN_PATHS = {
    google: File.join(ROOT, "google_token.json"),
    microsoft: File.join(ROOT, "microsoft_token.json")
  }.freeze

  # 明示 path: を使うアダプタ spec は保持し、新たなインスタンスも既定では一時領域を使う。
  module SettingsPath
    def initialize(defaults:, path: nil)
      super(defaults: defaults, path: path || SETTINGS_PATH)
    end
  end

  def self.reset!
    FileUtils.rm_rf(TICKETS_DIR)
    FileUtils.rm_f([SETTINGS_PATH, *TOKEN_PATHS.values])
  end
end

ENV.update(
  "APP_ENV" => "test", "STORE_BACKEND" => "file", "APP_TIMEZONE" => "Asia/Tokyo", "TZ" => "Asia/Tokyo",
  "ADMIN_PASSWORD" => "test-admin-password", "SESSION_SECRET" => "test-session-key" * 4,
  "TOKEN_ENCRYPTION_KEY" => "test-token-encryption-key",
  "GOOGLE_CLIENT_ID" => "test-google-client-id", "GOOGLE_CLIENT_SECRET" => "test-google-client-secret",
  "MS_CLIENT_ID" => "test-ms-client-id", "MS_CLIENT_SECRET" => "test-ms-client-secret",
  "MS_TENANT_ID" => "common", "HTTP_OPEN_TIMEOUT" => "5", "HTTP_READ_TIMEOUT" => "15",
  "TICKETS_DIR" => TestEnvironment::TICKETS_DIR
)
%w[LOG_FILE APP_BASE_URL APP_TRUST_PROXY SLACK_WEBHOOK_URL SLACK_MENTION].each { |key| ENV.delete(key) }
BCrypt::Engine.cost = BCrypt::Engine::MIN_COST
ENV["ADMIN_PASSWORD_DIGEST"] = BCrypt::Password.create(ENV.fetch("ADMIN_PASSWORD"))

# dotenv/load が呼ぶ load をテストプロセス内だけ抑止し、.env 自体を読まない。
Dotenv.define_singleton_method(:load) { |*| {} }
# 本番コードの定数を差し替えるのはテストプロセス内だけ。configure 前なのでロック先も隔離される。
FileTokenStore.send(:remove_const, :PATHS)
FileTokenStore.const_set(:PATHS, TestEnvironment::TOKEN_PATHS)
FileSettingsStore.prepend(TestEnvironment::SettingsPath)

at_exit { FileUtils.remove_entry(TestEnvironment::ROOT) }
