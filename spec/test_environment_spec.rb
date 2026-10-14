# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "テスト環境の隔離" do
  it "親の本番設定を無視し、初期化・再構成・保存・ロックを一時領域だけで行う" do
    script = <<~'RUBY'
      require ENV.fetch("SUKESAN_SPEC_HELPER")
      raise "環境の隔離に失敗" unless Sinatra::Application.test? && ENV.fetch("STORE_BACKEND") == "file"
      raise "タイムゾーンの隔離に失敗" unless APP_TIMEZONE == "Asia/Tokyo"
      raise "親の秘密が残った" unless SESSION_SECRET == "0123456789abcdef" * 4 &&
        ENV.fetch("TOKEN_ENCRYPTION_KEY") == "test-token-encryption-key" &&
        ENV.fetch("GOOGLE_CLIENT_ID") == "test-google-client-id" && !ENV.key?("SLACK_WEBHOOK_URL")
      raise "エミュレータ設定が消えた" unless ENV.fetch("FIRESTORE_EMULATOR_HOST") == "localhost:9999"

      key = Digest::SHA256.digest(ENV.fetch("TOKEN_ENCRYPTION_KEY"))
      TokenStore.configure(key)
      TicketStore.configure(key)
      %i[google microsoft].each do |provider|
        TokenStore.with_lock(provider) { TokenStore.save({ "access_token" => "dummy" }, provider) }
        raise "トークンを読み戻せない" unless TokenStore.load(provider) == { "access_token" => "dummy" }
      end
      SettingsStore.save("business_start" => "10:00")
      raise "設定を読み戻せない" unless SettingsStore.load.fetch("business_start") == "10:00"
      raise "新規設定ストアが隔離されない" unless FileSettingsStore.new(defaults: {}).load["business_start"] == "10:00"
      token = TicketStore.booking_lock.synchronize { TicketStore.create }
      raise "チケットを読み戻せない" unless TicketStore.find(token)

      root = TestEnvironment::ROOT
      paths = [*TestEnvironment::TOKEN_PATHS.values, TestEnvironment::SETTINGS_PATH]
      locks = paths.map { |path| "#{path}.lock" } +
        %w[.lock .booking.lock].map { |name| File.join(TestEnvironment::TICKETS_DIR, name) }
      raise "保存・ロックファイルが不足" unless (paths + locks).all? { |path| File.file?(path) }
      explicit = File.join(root, "explicit-settings.json")
      FileSettingsStore.new(defaults: {}, path: explicit).save("custom" => true)
      raise "明示の保存先が失われた" unless JSON.parse(File.read(explicit)) == { "custom" => true }
      TestEnvironment.reset!
      raise "状態が残った" unless TokenStore.load.nil? && TokenStore.load(:microsoft).nil? &&
        SettingsStore.load == SettingsStore::DEFAULT && TicketStore.all.empty?
      puts root
    RUBY
    env = {
      "APP_ENV" => "production", "STORE_BACKEND" => "firestore", "APP_TIMEZONE" => "America/New_York",
      "SESSION_SECRET" => "inherited-secret", "TOKEN_ENCRYPTION_KEY" => "inherited-key",
      "GOOGLE_CLIENT_ID" => "inherited-client", "SLACK_WEBHOOK_URL" => "https://example.invalid/webhook",
      "APP_BASE_URL" => "https://example.invalid", "APP_TRUST_PROXY" => "true",
      "TICKETS_DIR" => File.expand_path("../data/tickets", __dir__),
      "LOG_FILE" => File.expand_path("../log/server.log", __dir__),
      "FIRESTORE_EMULATOR_HOST" => "localhost:9999",
      "SUKESAN_SPEC_HELPER" => File.expand_path("spec_helper", __dir__)
    }
    guard = File.expand_path("support/protected_file_guard.rb", __dir__)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-r", guard, "-e", script)

    expect(status).to be_success, stderr
    expect(stderr).to be_empty
    expect(File.exist?(stdout.strip)).to be(false) # 自分で作った suite root は終了時に消す。
  end
end
