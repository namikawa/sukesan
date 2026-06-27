# frozen_string_literal: true

require_relative "token_cipher"
require_relative "ticket_status"
require_relative "stores/file_ticket_store"

# 1回限りのスケジュール調整 URL（チケット）ストアのファサード。
#
# 公開 API は変えず、STORE_BACKEND（file/firestore）で永続化の実装（アダプタ）を切り替える。
# 状態判定（status/expired?/active?）は永続化に依存しない純粋ロジック（TicketStatus）へ委譲する。
module TicketStore
  module_function

  # 起動時に暗号鍵（32 バイト）とバックエンドを設定する（TokenStore と同じ鍵を渡す）。
  def configure(key, backend: ENV.fetch("STORE_BACKEND", "file"))
    @backend = build_backend(backend, TokenCipher.new(key))
  end

  def build_backend(name, cipher)
    case name
    when "file" then FileTicketStore.new(cipher: cipher)
    when "firestore" then build_firestore_backend(cipher)
    else raise "未対応の STORE_BACKEND: #{name}"
    end
  end

  # Firestore 関連の require は firestore モードのときだけ行う（file モードで重い gem を読み込まない）。
  def build_firestore_backend(cipher)
    require_relative "stores/firestore_client"
    require_relative "stores/firestore_ticket_store"
    FirestoreTicketStore.new(cipher: cipher, firestore: FirestoreClient.build)
  end

  def backend
    @backend || raise("TicketStore.configure が未実行です")
  end

  # --- 永続化（アダプタへ委譲） ---
  def create(now: Time.now) = backend.create(now: now)
  def find(token, now: Time.now) = backend.find(token, now: now)
  def all(now: Time.now) = backend.all(now: now)
  def use!(token, attrs:, now: Time.now) = backend.use!(token, attrs: attrs, now: now)
  def reactivate!(token, now: Time.now) = backend.reactivate!(token, now: now)
  def revoke(token, now: Time.now) = backend.revoke(token, now: now)
  def prune!(now: Time.now) = backend.prune!(now: now)
  # 予約の臨界区間用ロック（backend ごとに適切なものを返す: file=flock / firestore=プロセス内 Mutex）。
  def booking_lock = backend.booking_lock

  # --- 状態判定（純粋ロジックへ委譲） ---
  def status(ticket, now: Time.now) = TicketStatus.status(ticket, now: now)
  def expired?(ticket, now: Time.now) = TicketStatus.expired?(ticket, now: now)
  def active?(ticket, now: Time.now) = TicketStatus.active?(ticket, now: now)
end
