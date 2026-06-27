# frozen_string_literal: true

require_relative "token_cipher"
require_relative "stores/file_token_store"

# OAuth トークン保管庫のファサード。
#
# 公開 API は変えず、STORE_BACKEND（file/firestore）で永続化の実装（アダプタ）を切り替える。
# Google（既定）は依頼者の未ログインリクエストでも管理者カレンダーへアクセスできるよう共有保存し、
# Microsoft（Outlook 同期用）も再起動後に連携を保持するため同じ仕組みで保存する。
module TokenStore
  module_function

  # 起動時に暗号鍵（32 バイト）とバックエンドを設定する。
  def configure(key, backend: ENV.fetch("STORE_BACKEND", "file"))
    @backend = build_backend(backend, TokenCipher.new(key))
  end

  def build_backend(name, cipher)
    case name
    when "file" then FileTokenStore.new(cipher: cipher)
    when "firestore" then build_firestore_backend(cipher)
    else raise "未対応の STORE_BACKEND: #{name}"
    end
  end

  # Firestore 関連の require は firestore モードのときだけ行う（file モードで重い gem を読み込まない）。
  def build_firestore_backend(cipher)
    require_relative "stores/firestore_client"
    require_relative "stores/firestore_token_store"
    FirestoreTokenStore.new(cipher: cipher, firestore: FirestoreClient.build)
  end

  def backend
    @backend || raise("TokenStore.configure が未実行です")
  end

  def with_lock(provider, &) = backend.with_lock(provider, &)
  def load(provider = :google) = backend.load(provider)
  def save(token_hash, provider = :google) = backend.save(token_hash, provider)
  def clear(provider = :google) = backend.clear(provider)
end
