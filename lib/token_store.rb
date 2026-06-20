# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require_relative "token_cipher"

# 管理者の Google OAuth トークンをサーバ側（ファイル）で共有保存する。
# セッション（ブラウザごと）と違い、公開ページの全利用者が同じ
# 管理者カレンダーの連携を使えるようにするための保管庫。
#
# トークンは TokenCipher で暗号化して保存し、ファイルは 0600 権限・原子的書き込みとする。
# 復号できない場合（鍵相違・改ざん・旧平文など）は「未連携」として扱う。
module TokenStore
  module_function

  PATH = File.expand_path("../data/google_token.json", __dir__)

  # 起動時に暗号鍵（32 バイト）を設定する。
  def configure(key)
    @cipher = TokenCipher.new(key)
  end

  def load
    return nil unless File.exist?(PATH)

    JSON.parse(@cipher.decrypt(File.read(PATH)))
  rescue StandardError
    nil
  end

  def save(token_hash)
    dir = File.dirname(PATH)
    FileUtils.mkdir_p(dir, mode: 0o700)
    tmp = File.join(dir, ".google_token.#{SecureRandom.hex(8)}.tmp")
    File.write(tmp, @cipher.encrypt(JSON.generate(token_hash)))
    File.chmod(0o600, tmp)
    File.rename(tmp, PATH) # 同一ファイルシステム内での rename は原子的
  end

  def clear
    FileUtils.rm_f(PATH)
  end
end
