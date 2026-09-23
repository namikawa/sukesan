# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "エラーハンドリング" do
  # テスト環境の既定は raise_errors: true（例外がそのまま伝播）のため、
  # 本番相当（error ハンドラで処理）に切り替えて検証し、終了後に必ず戻す。
  around do |example|
    app.set :raise_errors, false
    example.run
  ensure
    app.set :raise_errors, true
  end

  it "500 の本文・標準エラー・rack.errors に秘密を出さず、例外クラスと発生位置だけを残す" do
    allow(TicketStore).to receive(:find).and_raise(RuntimeError, "internal-secret-detail")
    rack_errors = StringIO.new

    expect { get "/t/whatever", {}, "rack.errors" => rack_errors }
      .to output(/\A\[error\] RuntimeError at (?![^\n]*internal-secret-detail)[^\n]+\n\z/).to_stderr
    expect(last_response.status).to eq(500)
    expect(last_response.body).to include("エラーが発生しました")
    expect(last_response.body).not_to include("internal-secret-detail")
    expect(rack_errors.string).not_to include("internal-secret-detail")
    expect(app.show_exceptions).to be(false)
    expect(app.dump_errors).to be(false)
  end

  it "development 起動時も例外の秘密を応答と診断出力に出さない" do
    script = <<~'RUBY'
      require "stringio"
      require ENV.fetch("SUKESAN_APP_PATH")

      TicketStore.define_singleton_method(:find) { |_token| raise "dummy-development-secret" }
      errors = StringIO.new
      response = Rack::MockRequest.new(Sinatra::Application).get("/t/dummy", "rack.errors" => errors)
      puts "RESULT:#{JSON.generate(status: response.status, body: response.body, rack_errors: errors.string)}"
    RUBY
    env = { "APP_ENV" => "development", "LOG_TO_STDOUT" => "true",
            "SUKESAN_APP_PATH" => File.expand_path("../../app", __dir__) }

    Dir.mktmpdir do |dir|
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-e", script, chdir: dir)
      expect(status).to be_success
      result = JSON.parse(stdout.lines.find { |line| line.start_with?("RESULT:") }.delete_prefix("RESULT:"))

      expect(result["status"]).to eq(500)
      expect(result["body"]).to include("エラーが発生しました")
      expect(result["body"]).not_to include("dummy-development-secret")
      expect(result["rack_errors"]).not_to include("dummy-development-secret")
      expect(stderr).not_to include("dummy-development-secret")
    end
  end
end
