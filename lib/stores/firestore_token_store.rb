# frozen_string_literal: true

require "json"
require "google/cloud/firestore"

# OAuth トークンの Firestore 永続化アダプタ（STORE_BACKEND=firestore）。
#
# ドキュメント tokens/{provider} に、トークン全体を TokenCipher で暗号化した文字列（enc）として保存する
# （クエリ不要なため丸ごと暗号化）。復号できない場合は「未連携」として扱う（fail-closed）。
#
# with_lock はプロセス内 Mutex（best-effort）。同一インスタンス内の並行 refresh は防げるが、複数インスタンス間
# では直列化されない（refresh token ローテーション時の取りこぼしは稀に起こり得る点を許容する）。
class FirestoreTokenStore
  COLLECTION = "tokens"

  def initialize(cipher:, firestore:)
    @cipher = cipher
    @firestore = firestore
    @locks = {}
    @locks_guard = Mutex.new
  end

  def with_lock(provider, &) = lock_for(provider).synchronize(&)

  def load(provider = :google)
    snapshot = doc(provider).get
    return nil unless snapshot.exists?

    enc = snapshot[:enc]
    return nil if enc.nil?

    JSON.parse(@cipher.decrypt(enc))
  rescue StandardError => e
    warn "[FirestoreTokenStore] 読み込み失敗 (provider=#{provider}): #{e.class}（未連携として扱います）"
    nil
  end

  def save(token_hash, provider = :google)
    doc(provider).set({ enc: @cipher.encrypt(JSON.generate(token_hash)) })
  end

  def clear(provider = :google)
    doc(provider).delete
  end

  private

  def doc(provider) = @firestore.doc("#{COLLECTION}/#{provider}")

  def lock_for(provider)
    @locks_guard.synchronize { @locks[provider] ||= Mutex.new }
  end
end
