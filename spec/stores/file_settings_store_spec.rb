# frozen_string_literal: true

require "json"
require "tmpdir"
require "stores/file_settings_store"

RSpec.describe FileSettingsStore do
  # ロケール未設定（LANG を渡さない launchd / systemd 配下）を再現する。
  # Encoding.default_external= は $VERBOSE 時に警告を出すため抑止し、ensure で必ず元に戻す。
  def with_default_external(encoding)
    prev = Encoding.default_external
    verbose = $VERBOSE
    $VERBOSE = nil
    Encoding.default_external = encoding
    yield
  ensure
    Encoding.default_external = prev
    $VERBOSE = verbose
  end

  it "既定外部エンコーディングが US-ASCII でも日本語を含む設定を読める" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, JSON.generate({ "api_keys" => { "社内ツール" => { "digest" => "abc" } } }))
      store = described_class.new(defaults: { "api_keys" => {} }, path: path)

      loaded = with_default_external(Encoding::US_ASCII) { store.load }

      expect(loaded["api_keys"]).to eq("社内ツール" => { "digest" => "abc" })
    end
  end
end
