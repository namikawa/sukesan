# frozen_string_literal: true

require "openssl"
require_relative "token_cipher"
require_relative "ticket_status"
require_relative "stores/file_ticket_store"

# 1回限りのスケジュール調整 URL（チケット）ストアのファサード。
#
# 公開 API は変えず、STORE_BACKEND（file/firestore）で永続化の実装（アダプタ）を切り替える。
# 状態判定（status/active?/held?）は永続化に依存しない純粋ロジック（TicketStatus）へ委譲する。
module TicketStore
  module_function

  # 起動時に暗号鍵（32 バイト）とバックエンドを設定する（TokenStore と同じ鍵を渡す）。
  def configure(key, backend: ENV.fetch("STORE_BACKEND", "file"))
    @backend = build_backend(backend, key)
  end

  def build_backend(name, key)
    cipher = TokenCipher.new(key)
    case name
    when "file" then FileTicketStore.new(cipher: cipher)
    when "firestore" then build_firestore_backend(cipher, key)
    else raise "未対応の STORE_BACKEND: #{name}"
    end
  end

  # Firestore 関連の require は firestore モードのときだけ行う（file モードで重い gem を読み込まない）。
  # doc id 用の HMAC 鍵は暗号鍵から用途別に派生する（生 token を doc id に出さないため）。
  def build_firestore_backend(cipher, key)
    require_relative "stores/firestore_client"
    require_relative "stores/firestore_ticket_store"
    doc_id_key = OpenSSL::HMAC.digest("SHA256", key, "sukesan-ticket-doc-id")
    FirestoreTicketStore.new(cipher: cipher, firestore: FirestoreClient.build, doc_id_key: doc_id_key)
  end

  def backend
    @backend || raise("TicketStore.configure が未実行です")
  end

  # --- 永続化（アダプタへ委譲） ---
  # ttl_hours: 発行時に選んだ有効期間（許可値の検証は呼び出し側で TicketStatus.normalize_ttl_hours を通す）。
  def create(now: Time.now, ttl_hours: TicketStatus::DEFAULT_TTL_HOURS) = backend.create(now: now, ttl_hours: ttl_hours)
  def find(token, now: Time.now) = backend.find(token, now: now)
  def all(now: Time.now) = backend.all(now: now)
  def use!(token, attrs:, now: Time.now) = backend.use!(token, attrs: attrs, now: now)
  def reactivate!(token, now: Time.now) = backend.reactivate!(token, now: now)
  def revoke(token, now: Time.now) = backend.revoke(token, now: now)
  # --- 仮押さえ（複数カレンダー仮押さえ機能） ---
  def hold!(token, attrs:, now: Time.now) = backend.hold!(token, attrs: attrs, now: now)

  def confirm_hold!(token, slot_start:, attrs:, now: Time.now)
    backend.confirm_hold!(token, slot_start: slot_start, attrs: attrs, now: now)
  end

  def remove_hold!(token, slot_start:, now: Time.now) = backend.remove_hold!(token, slot_start: slot_start, now: now)
  def cancel_hold!(token, now: Time.now) = backend.cancel_hold!(token, now: now)
  # 予約の臨界区間用ロック（backend ごとに適切なものを返す: file=flock / firestore=プロセス内 Mutex）。
  def booking_lock = backend.booking_lock

  # --- 状態判定（純粋ロジックへ委譲） ---
  def status(ticket, now: Time.now) = TicketStatus.status(ticket, now: now)
  def active?(ticket, now: Time.now) = TicketStatus.active?(ticket, now: now)
  def held?(ticket, now: Time.now) = TicketStatus.held?(ticket, now: now)
end
