# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require_relative "token_cipher"
require_relative "cross_process_lock"

# OAuth トークンをサーバ側（ファイル）で暗号化保存する保管庫。
#
# Google（既定）は、ログインしていない依頼者のリクエストでも管理者カレンダーへ
# アクセスできるよう共有保存する。Microsoft（Outlook 同期用）も再起動後に連携を
# 保持するため同じ仕組みで保存する。provider で保存先を切り替える。
#
# トークンは TokenCipher で暗号化して保存し、ファイルは 0600 権限・原子的書き込みとする。
# 復号できない場合（鍵相違・改ざん・旧平文など）は「未連携」として扱う。
module TokenStore
  module_function

  PATHS = {
    google: File.expand_path("../data/google_token.json", __dir__),
    microsoft: File.expand_path("../data/microsoft_token.json", __dir__)
  }.freeze

  # プロバイダ別ロック。トークン更新（load→refresh→save）を直列化し、並行 refresh や
  # 保存競合（refresh token ローテーション時の取りこぼし）を防ぐために使う。
  LOCKS = PATHS.transform_values { |path| CrossProcessLock.new("#{path}.lock") }.freeze

  # 起動時に暗号鍵（32 バイト）を設定する。
  def configure(key)
    @cipher = TokenCipher.new(key)
  end

  # 指定プロバイダのトークン更新を直列化する（呼び出し側で load→refresh→save を包む）。
  def with_lock(provider, &)
    LOCKS.fetch(provider).synchronize(&)
  end

  def load(provider = :google)
    path = PATHS.fetch(provider)
    return nil unless File.exist?(path)

    JSON.parse(@cipher.decrypt(File.read(path)))
  rescue StandardError
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
