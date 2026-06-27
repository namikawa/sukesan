# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require_relative "../cross_process_lock"

# OAuth トークンのファイル永続化アダプタ（STORE_BACKEND=file）。
#
# provider（:google / :microsoft）で保存先を切り替える。トークンは TokenCipher で暗号化し、
# 0600 権限・原子的書き込み（tmp→rename）で保存する。復号できない場合（鍵相違・改ざん・旧平文など）は
# 「未連携」として扱う（fail-closed）。トークン更新（load→refresh→save）はプロバイダ別ロックで直列化する。
class FileTokenStore
  PATHS = {
    google: File.expand_path("../../data/google_token.json", __dir__),
    microsoft: File.expand_path("../../data/microsoft_token.json", __dir__)
  }.freeze

  def initialize(cipher:)
    @cipher = cipher
    # プロバイダ別ロック。並行 refresh や保存競合（refresh token ローテーション時の取りこぼし）を防ぐ。
    @locks = PATHS.transform_values { |path| CrossProcessLock.new("#{path}.lock") }
  end

  # 指定プロバイダのトークン更新を直列化する（呼び出し側で load→refresh→save を包む）。
  def with_lock(provider, &) = @locks.fetch(provider).synchronize(&)

  def load(provider = :google)
    path = PATHS.fetch(provider)
    return nil unless File.exist?(path)

    JSON.parse(@cipher.decrypt(File.read(path)))
  rescue StandardError => e
    # 復号・パース失敗時は未連携として扱う（fail-closed）。鍵ズレ等の調査用に種別とパスだけ残す
    # （内容・例外メッセージは秘密を含み得るため出さない）。
    warn "[FileTokenStore] 読み込み失敗 #{path} (provider=#{provider}): #{e.class}（未連携として扱います）"
    nil
  end

  def save(token_hash, provider = :google)
    path = PATHS.fetch(provider)
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir, mode: 0o700)
    tmp = File.join(dir, ".#{File.basename(path)}.#{SecureRandom.hex(8)}.tmp")
    File.write(tmp, @cipher.encrypt(JSON.generate(token_hash)))
    File.chmod(0o600, tmp)
    File.rename(tmp, path) # 同一ファイルシステム内での rename は原子的
  end

  def clear(provider = :google)
    FileUtils.rm_f(PATHS.fetch(provider))
  end
end
