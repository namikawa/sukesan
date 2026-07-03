# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "time"
require "openssl"
require_relative "../cross_process_lock"
require_relative "../ticket_status"
require_relative "../ticket_transitions"

# チケットのファイル永続化アダプタ（STORE_BACKEND=file）。
#
# 週次ローテーションのため、ISO 週ごとのファイル（tickets-YYYY-Www.json）に分割して保存する。
# - 検索・更新は直近 SEARCH_WEEKS（3 週）のファイル、一覧は直近 RETENTION_DAYS（30日）分のみを対象とし、
#   古い週ファイルは自動削除する。
# - 保存内容（トークン・依頼者名・予定名・参加者など）は TokenCipher で暗号化し、0600 で保存する。
# - read-modify-write は CrossProcessLock（Mutex＋flock）で直列化する。書き込みはアトミック（tmp→rename）なので、
#   読み取り（find/all）はロック不要。
# - 状態遷移の内容判定・組み立ては TicketTransitions（純粋ロジック）に委譲する。
class FileTicketStore
  RETENTION_DAYS = 30 # 管理画面の一覧対象（直近 30 日）
  # 物理保持する週ファイル数。当週＋過去 5 週＝6 バケットを保持し、6 週以上前の週ファイルは prune! で物理削除する。
  # 30 日表示を確実にカバーするための最小バケット数でもある（ISO 週境界の最悪ケースで 6 バケット必要）。
  KEEP_WEEKS = 6
  # 検索・更新で探す週ファイル数。チケットの寿命は最長「発行 24h ＋仮押さえ 7 日 ≒ 8 日」で、
  # ISO 週境界の最悪ケースで 3 バケットにまたがるため 3 週分を見る。
  SEARCH_WEEKS = 3

  def initialize(cipher:, dir: nil)
    @cipher = cipher
    @dir = dir
    @lock = CrossProcessLock.new(-> { File.join(self.dir, ".lock") })
  end

  def dir
    @dir || ENV.fetch("TICKETS_DIR") { File.expand_path("../../data/tickets", __dir__) }
  end

  # 予約の臨界区間（空き再確認〜カレンダー登録）を直列化するロック。チケット保存先と同じ
  # ディレクトリにロックファイルを置く。Mutex＋flock で同一ホスト上の複数プロセスでも有効。
  def booking_lock = (@booking_lock ||= CrossProcessLock.new(-> { File.join(dir, ".booking.lock") }))

  # 新しいワンタイム URL を発行し、トークンを返す。
  def create(now: Time.now)
    token = SecureRandom.urlsafe_base64(32)
    @lock.synchronize do
      key = bucket_key(now)
      data = load_bucket(key)
      data[token] = { "token" => token, "created_at" => now.iso8601, "status" => "active" }
      write_bucket(key, data)
      prune!(now: now)
    end
    token
  end

  def find(token, now: Time.now)
    recent_bucket_keys(now, SEARCH_WEEKS).each do |key|
      data = load_bucket(key)
      return data[token.to_s] if data.key?(token.to_s)
    end
    nil
  end

  # 直近 RETENTION_DAYS 日に発行されたチケットを新しい順で返す（管理画面の一覧用）。
  def all(now: Time.now)
    cutoff = now - (RETENTION_DAYS * 86_400)
    recent_bucket_keys(now, KEEP_WEEKS)
      .flat_map { |key| load_bucket(key).values }
      .select { |t| created_after?(t, cutoff) }
      .sort_by { |t| t["created_at"] }
      .reverse
  end

  # 使用可能なら使用済みにして true。使えない場合は false。
  def use!(token, attrs:, now: Time.now)
    apply_transition(token, now: now) { |t| TicketTransitions.use(t, attrs: attrs, now: now) } || false
  end

  # 登録に失敗したときなど、使用可能状態へ戻す。
  def reactivate!(token, now: Time.now)
    apply_transition(token, now: now) { |t| TicketTransitions.reactivate(t) } || false
  end

  # 仮押さえ（active → held）。attrs には requester/title/holds/holder_key を渡す。
  def hold!(token, attrs:, now: Time.now)
    apply_transition(token, now: now) { |t| TicketTransitions.hold(t, attrs: attrs, now: now) } || false
  end

  # 仮押さえから 1 件を選んで確定（held → used）。成功時は確定前の holds を返す（失敗は nil）。
  def confirm_hold!(token, slot_start:, attrs:, now: Time.now)
    apply_transition(token, now: now) do |t|
      TicketTransitions.confirm_hold(t, slot_start: slot_start, attrs: attrs, now: now)
    end
  end

  # 仮押さえから 1 件を取り除く（最後の 1 件なら cancelled へ）。取り除いたエントリを返す（失敗は nil）。
  def remove_hold!(token, slot_start:, now: Time.now)
    apply_transition(token, now: now) { |t| TicketTransitions.remove_hold(t, slot_start: slot_start, now: now) }
  end

  # 仮押さえをすべて取りやめて終了（held → cancelled）。取りやめた holds を返す（失敗は nil）。
  def cancel_hold!(token, now: Time.now)
    apply_transition(token, now: now) { |t| TicketTransitions.cancel_hold(t, now: now) }
  end

  # 管理者による無効化（active/held → revoked）。成功時は遷移前のチケットを返す（失敗は false）。
  def revoke(token, now: Time.now)
    apply_transition(token, now: now) { |t| TicketTransitions.revoke(t, now: now) } || false
  end

  # 保持対象（直近 KEEP_WEEKS 週）以外の週ファイルを削除する。
  def prune!(now: Time.now)
    keep = recent_bucket_keys(now, KEEP_WEEKS)
    Dir.glob(File.join(dir, "tickets-*.json")).each do |file|
      key = File.basename(file, ".json").delete_prefix("tickets-")
      File.delete(file) unless keep.include?(key)
    end
  end

  private

  # 状態遷移を read-modify-write で適用する。ブロックは TicketTransitions の規約
  # （[遷移後チケット, 戻り値] または nil）で応答し、nil（遷移不可）なら何も書かず nil を返す。
  def apply_transition(token, now:)
    value = nil
    @lock.synchronize do
      recent_bucket_keys(now, SEARCH_WEEKS).each do |key|
        data = load_bucket(key)
        next unless data.key?(token.to_s)

        updated, value = yield(data[token.to_s])
        return nil if updated.nil?

        data[token.to_s] = updated
        write_bucket(key, data)
        return value
      end
    end
    nil
  end

  def created_after?(ticket, cutoff)
    Time.iso8601(ticket["created_at"]) >= cutoff
  rescue ArgumentError
    false
  end

  def bucket_key(time)
    time.strftime("%G-W%V")
  end

  def recent_bucket_keys(now, weeks)
    (0...weeks).map { |i| bucket_key(now - (i * 7 * 86_400)) }.uniq
  end

  def load_bucket(key)
    path = File.join(dir, "tickets-#{key}.json")
    return {} unless File.exist?(path)

    JSON.parse(@cipher.decrypt(File.read(path)))
  rescue JSON::ParserError, OpenSSL::Cipher::CipherError, ArgumentError => e
    # 復号・パースできないデータ（破損・改ざん・鍵不一致）は空として扱う（fail-closed）。
    # 原因調査用に種別とパスだけ残す（内容・例外メッセージは秘密を含み得るため出さない）。
    warn "[FileTicketStore] 読み込み失敗 #{path}: #{e.class}（空として扱います）"
    {}
  end

  def write_bucket(key, data)
    FileUtils.mkdir_p(dir, mode: 0o700)
    path = File.join(dir, "tickets-#{key}.json")
    tmp = "#{path}.#{SecureRandom.hex(8)}.tmp"
    File.write(tmp, @cipher.encrypt(JSON.generate(data)))
    File.chmod(0o600, tmp) # 準個人情報を含むため本人のみ読み書き可に絞る
    File.rename(tmp, path) # 同一ファイルシステム内での rename は Atomic
  end
end
