# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "time"
require "openssl"
require_relative "../cross_process_lock"
require_relative "../ticket_status"

# チケットのファイル永続化アダプタ（STORE_BACKEND=file）。
#
# 週次ローテーションのため、ISO 週ごとのファイル（tickets-YYYY-Www.json）に分割して保存する。
# - 検索は「今週・先週」の 2 ファイル、一覧は直近 RETENTION_DAYS（30日）分のみを対象とし、古い週ファイルは自動削除する。
# - 保存内容（トークン・依頼者名・予定名・参加者など）は TokenCipher で暗号化し、0600 で保存する。
# - read-modify-write は CrossProcessLock（Mutex＋flock）で直列化する。書き込みはアトミック（tmp→rename）なので、
#   読み取り（find/all）はロック不要。
class FileTicketStore
  RETENTION_DAYS = 30 # 管理画面の一覧対象（直近 30 日）
  # 物理保持する週ファイル数。当週＋過去 5 週＝6 バケットを保持し、6 週以上前の週ファイルは prune! で物理削除する。
  # 30 日表示を確実にカバーするための最小バケット数でもある（ISO 週境界の最悪ケースで 6 バケット必要）。
  KEEP_WEEKS = 6

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
    recent_bucket_keys(now, 2).each do |key|
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
    update(token, now: now) do |ticket|
      return false unless TicketStatus.active?(ticket, now: now)

      ticket.merge(attrs).merge("status" => "used", "used_at" => now.iso8601)
    end
  end

  # 登録に失敗したときなど、使用可能状態へ戻す。
  def reactivate!(token, now: Time.now)
    update(token, now: now) do |ticket|
      ticket.except("status", "used_at", "requester", "title", "slot_start", "slot_end", "attendees")
            .merge("status" => "active")
    end
  end

  def revoke(token, now: Time.now)
    update(token, now: now) do |ticket|
      return false unless TicketStatus.active?(ticket, now: now)

      ticket.merge("status" => "revoked")
    end
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

  def update(token, now:)
    @lock.synchronize do
      recent_bucket_keys(now, 2).each do |key|
        data = load_bucket(key)
        next unless data.key?(token.to_s)

        data[token.to_s] = yield(data[token.to_s])
        write_bucket(key, data)
        return true
      end
      false
    end
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
