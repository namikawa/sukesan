# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "openssl"
require "google/cloud/firestore"
require_relative "../ticket_status"

# チケット（1回限りのワンタイム URL）の Firestore 永続化アダプタ（STORE_BACKEND=firestore）。
#
# コレクション tickets、doc id = HMAC(token)。token は bearer credential なので、平文露出しやすい doc id
# （Firestore コンソール・監査ログ・バックアップ等に残る）には出さず、HMAC 化した値を使う。クエリ・TTL 用の
# 制御フィールド（status / created_at_ts / purge_at）は平文で持ち、token・依頼者名・予定名・参加者などの PII を
# 含むチケット全体は TokenCipher で暗号化した文字列（enc）として保存する。
#
# use! / revoke / reactivate! は Firestore トランザクションで「active のときだけ遷移」を Atomic に行うため、
# 同一チケットの二重使用はロック無しで防げる（flock 不要）。物理削除は Firestore の TTL ポリシー（purge_at）に委ね、
# prune! は no-op とする。チケットの有効期限（24時間）は TicketStatus が created_at から判定する（物理削除とは独立）。
class FirestoreTicketStore
  COLLECTION = "tickets"
  RETENTION_DAYS = 30 # Firestore TTL ポリシー（purge_at）で物理削除するまでの保持日数（管理画面の一覧対象）

  def initialize(cipher:, firestore:, doc_id_key:)
    @cipher = cipher
    @firestore = firestore
    @doc_id_key = doc_id_key
    @col = firestore.col(COLLECTION)
  end

  # 予約処理の臨界区間（空き再確認〜登録）用ロック。プロセス内 Mutex なので同一インスタンス内のみ直列化する。
  # 同一チケットの二重使用は use! のトランザクションで防げるが、別チケットによる同一スロットの二重予約防止は
  # この直列化に依存するため、単一インスタンス運用（Cloud Run は max-instances=1）が前提。複数インスタンスで
  # スケールする場合はスロット予約 document（slot_reservations）等による分散排他が別途必要。
  def booking_lock = (@booking_lock ||= Mutex.new)

  def create(now: Time.now)
    token = SecureRandom.urlsafe_base64(32)
    ticket = { "token" => token, "created_at" => now.iso8601, "status" => "active" }
    doc(token).set(fields(ticket))
    token
  end

  # now: はファイルバックエンドとのインターフェース対称性のための引数（Firestore は doc id 直引きで不要）。
  def find(token, now: Time.now) # rubocop:disable Lint/UnusedMethodArgument
    decode(doc(token).get)
  end

  # 直近 RETENTION_DAYS 日に発行されたチケットを新しい順で返す（管理画面の一覧用）。
  def all(now: Time.now)
    cutoff = now - (RETENTION_DAYS * 86_400)
    @col.where("created_at_ts", ">=", cutoff).order("created_at_ts", :desc).get
        .filter_map { |snapshot| decode(snapshot) }
  end

  # 使用可能なら使用済みにして true。使えない場合は false。
  def use!(token, attrs:, now: Time.now)
    transition(token, now: now, require_active: true) do |ticket|
      ticket.merge(attrs).merge("status" => "used", "used_at" => now.iso8601)
    end
  end

  # 登録に失敗したときなど、使用可能状態へ戻す。
  def reactivate!(token, now: Time.now)
    transition(token, now: now, require_active: false) do |ticket|
      ticket.except("status", "used_at", "requester", "title", "slot_start", "slot_end", "attendees")
            .merge("status" => "active")
    end
  end

  def revoke(token, now: Time.now)
    transition(token, now: now, require_active: true) do |ticket|
      ticket.merge("status" => "revoked")
    end
  end

  # 物理削除は Firestore の TTL ポリシー（purge_at）に委ねるため no-op。
  def prune!(now: Time.now); end

  private

  def doc(token) = @col.doc(doc_id(token))

  # 生 token を doc id（平文メタデータ）に出さないため、HMAC 化した値を doc id に使う。
  def doc_id(token) = OpenSSL::HMAC.hexdigest("SHA256", @doc_id_key, token.to_s)

  # 制御用の平文フィールド（クエリ・TTL 用）＋ PII を含む全体の暗号文。
  def fields(ticket)
    created = Time.iso8601(ticket["created_at"])
    {
      status: ticket["status"],
      created_at_ts: created,
      purge_at: created + (RETENTION_DAYS * 86_400), # Firestore TTL ポリシーの対象フィールド
      enc: @cipher.encrypt(JSON.generate(ticket))
    }
  end

  def decode(snapshot)
    return nil unless snapshot.exists?

    enc = snapshot[:enc]
    return nil if enc.nil?

    JSON.parse(@cipher.decrypt(enc))
  rescue StandardError => e
    warn "[FirestoreTicketStore] 読み込み失敗: #{e.class}（無効として扱います）"
    nil
  end

  # active 判定とフィールド更新を 1 トランザクションで Atomic に行う（同一チケットの二重遷移を防ぐ）。
  def transition(token, now:, require_active:)
    updated = false
    @firestore.transaction do |tx|
      ticket = decode(tx.get(doc(token)))
      next if ticket.nil?
      next if require_active && !TicketStatus.active?(ticket, now: now)

      tx.set(doc(token), fields(yield(ticket)))
      updated = true
    end
    updated
  end
end
