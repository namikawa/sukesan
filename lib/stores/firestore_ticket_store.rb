# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "openssl"
require "google/cloud/firestore"
require_relative "../ticket_status"
require_relative "../ticket_transitions"

# チケット（1回限りのワンタイム URL）の Firestore 永続化アダプタ（STORE_BACKEND=firestore）。
#
# コレクション tickets、doc id = HMAC(token)。token は bearer credential なので、平文露出しやすい doc id
# （Firestore コンソール・監査ログ・バックアップ等に残る）には出さず、HMAC 化した値を使う。クエリ・TTL 用の
# 制御フィールド（status / created_at_ts / purge_at）は平文で持ち、token・依頼者名・予定名・参加者などの PII を
# 含むチケット全体は TokenCipher で暗号化した文字列（enc）として保存する。
#
# 状態遷移（use!/hold!/confirm_hold! 等）は Firestore トランザクションで「遷移可能なときだけ更新」を
# Atomic に行うため、同一チケットの二重使用・二重決定はロック無しで防げる（flock 不要）。
# 遷移の内容判定・組み立ては TicketTransitions（純粋ロジック）に委譲する。
# 物理削除は Firestore の TTL ポリシー（purge_at）に委ね、prune! は no-op とする。
class FirestoreTicketStore
  COLLECTION = "tickets"
  DISPLAY_DAYS = 30 # 管理画面の一覧対象（直近 30 日）
  PURGE_DAYS = 42   # Firestore TTL ポリシー（purge_at）で物理削除するまでの保持日数（6 週間。file の KEEP_WEEKS=6 と整合）

  def initialize(cipher:, firestore:, doc_id_key:)
    @cipher = cipher
    @firestore = firestore
    @doc_id_key = doc_id_key
    @col = firestore.col(COLLECTION)
  end

  # 予約処理の臨界区間（空き再確認〜登録）用ロック。プロセス内 Mutex なので同一インスタンス内のみ直列化する。
  # 同一チケットの二重使用・二重決定はトランザクションで防げるが、別チケットによる同一スロットの二重予約防止は
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

  # 直近 DISPLAY_DAYS 日に発行されたチケットを新しい順で返す（管理画面の一覧用）。
  def all(now: Time.now)
    cutoff = now - (DISPLAY_DAYS * 86_400)
    @col.where("created_at_ts", ">=", cutoff).order("created_at_ts", :desc).get
        .filter_map { |snapshot| decode(snapshot) }
  end

  # 使用可能なら使用済みにして true。使えない場合は false。
  def use!(token, attrs:, now: Time.now)
    apply_transition(token) { |t| TicketTransitions.use(t, attrs: attrs, now: now) } || false
  end

  # 登録に失敗したときなど、使用可能状態へ戻す。
  def reactivate!(token, now: Time.now) # rubocop:disable Lint/UnusedMethodArgument
    apply_transition(token) { |t| TicketTransitions.reactivate(t) } || false
  end

  # 仮押さえ（active → held）。attrs には requester/title/holds/holder_key を渡す。
  def hold!(token, attrs:, now: Time.now)
    apply_transition(token) { |t| TicketTransitions.hold(t, attrs: attrs, now: now) } || false
  end

  # 仮押さえから 1 件を選んで確定（held → used）。成功時は確定前の holds を返す（失敗は nil）。
  def confirm_hold!(token, slot_start:, attrs:, now: Time.now)
    apply_transition(token) do |t|
      TicketTransitions.confirm_hold(t, slot_start: slot_start, attrs: attrs, now: now)
    end
  end

  # 仮押さえから 1 件を取り除く（最後の 1 件なら cancelled へ）。取り除いたエントリを返す（失敗は nil）。
  def remove_hold!(token, slot_start:, now: Time.now)
    apply_transition(token) { |t| TicketTransitions.remove_hold(t, slot_start: slot_start, now: now) }
  end

  # 仮押さえをすべて取りやめて終了（held → cancelled）。取りやめた holds を返す（失敗は nil）。
  def cancel_hold!(token, now: Time.now)
    apply_transition(token) { |t| TicketTransitions.cancel_hold(t, now: now) }
  end

  # 管理者による無効化（active/held → revoked）。成功時は遷移前のチケットを返す（失敗は false）。
  def revoke(token, now: Time.now)
    apply_transition(token) { |t| TicketTransitions.revoke(t, now: now) } || false
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
      purge_at: created + (PURGE_DAYS * 86_400), # Firestore TTL ポリシーの対象フィールド（6 週間で物理削除）
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

  # 状態遷移を 1 トランザクションで Atomic に適用する。ブロックは TicketTransitions の規約
  # （[遷移後チケット, 戻り値] または nil）で応答し、nil（遷移不可）なら何も書かず nil を返す。
  def apply_transition(token)
    value = nil
    @firestore.transaction do |tx|
      value = nil # トランザクション再試行時に前回試行の値を持ち越さない
      ticket = decode(tx.get(doc(token)))
      next if ticket.nil?

      updated, value = yield(ticket)
      next if updated.nil?

      tx.set(doc(token), fields(updated))
    end
    value
  end
end
