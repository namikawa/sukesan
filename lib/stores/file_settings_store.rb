# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require_relative "../cross_process_lock"

# 調整可能な時間帯などの設定のファイル永続化アダプタ（STORE_BACKEND=file）。
#
# save の read-modify-write は CrossProcessLock で直列化し、複数画面（/settings・/sync）からの
# 同時保存で一部設定が巻き戻るのを防ぐ。0600・原子的書き込み（tmp→rename）で保存する。
# 読み取り（load）は原子的 rename 前提でロック不要。既定値（defaults）は呼び出し側から注入する。
class FileSettingsStore
  def initialize(defaults:, path: nil)
    @defaults = defaults
    @path = path || File.expand_path("../../data/settings.json", __dir__)
    @lock = CrossProcessLock.new("#{@path}.lock")
  end

  def load
    return @defaults.dup unless File.exist?(@path)

    @defaults.merge(JSON.parse(File.read(@path)))
  rescue JSON::ParserError
    @defaults.dup
  end

  # 指定した項目だけを既存設定にマージして保存する（未指定の項目は保持する）。
  def save(attrs)
    @lock.synchronize do
      data = load.merge(attrs.transform_keys(&:to_s))
      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir, mode: 0o700)
      tmp = File.join(dir, ".settings.#{SecureRandom.hex(8)}.tmp")
      File.write(tmp, JSON.generate(data))
      File.chmod(0o600, tmp)
      File.rename(tmp, @path) # 同一ファイルシステム内での rename は原子的
      data
    end
  end
end
