# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require "time"

# 1回限りのスケジュール調整 URL（チケット）を永続化するストア。
#
# 週次ローテーションのため、ISO 週ごとのファイル（tickets-YYYY-Www.json）に分割して保存する。
# - 発行から TTL_SECONDS（24時間）経過、または登録（使用）で無効になる。管理者は手動失効も可能。
# - 有効なチケットは最大 24 時間なので、検索は「今週・先週」の 2 ファイルのみ見れば十分。
# - 一覧（管理画面）は直近 RETENTION_DAYS（30日）分のみを対象とし、古い週ファイルは自動削除する。
module TicketStore
  module_function

  TTL_SECONDS = 24 * 60 * 60
  RETENTION_DAYS = 30
  KEEP_WEEKS = 6 # 30日をカバーするため、保持・走査する週ファイル数
  MUTEX = Mutex.new

  def dir
    ENV.fetch("TICKETS_DIR") { File.expand_path("../data/tickets", __dir__) }
  end

  # 新しいワンタイム URL を発行し、トークンを返す。
  def create(now: Time.now)
    token = SecureRandom.urlsafe_base64(32)
    MUTEX.synchronize do
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

  def expired?(ticket, now: Time.now)
    Time.iso8601(ticket["created_at"]) + TTL_SECONDS < now
  rescue ArgumentError
    true
  end

  # 表示用ステータス: used / revoked / expired / active
  def status(ticket, now: Time.now)
    return ticket["status"] if %w[used revoked].include?(ticket["status"])

    expired?(ticket, now: now) ? "expired" : "active"
  end

  def active?(ticket, now: Time.now)
    !ticket.nil? && status(ticket, now: now) == "active"
  end

  # 使用可能なら使用済みにして true。使えない場合は false。
  def use!(token, attrs:, now: Time.now)
    update(token, now: now) do |ticket|
      return false unless status(ticket, now: now) == "active"

      ticket.merge(attrs).merge("status" => "used", "used_at" => now.iso8601)
    end
  end

  # 登録に失敗したときなど、使用可能状態へ戻す。
  def reactivate!(token, now: Time.now)
    update(token, now: now) do |ticket|
      ticket.except("status", "used_at", "requester", "title", "slot_start", "slot_end")
            .merge("status" => "active")
    end
  end

  def revoke(token, now: Time.now)
    update(token, now: now) do |ticket|
      return false unless status(ticket, now: now) == "active"

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

  # --- 内部ヘルパ ---

  def update(token, now:)
    MUTEX.synchronize do
      recent_bucket_keys(now, 2).each do |key|
        data = load_bucket(key)
        next unless data.key?(token.to_s)

        updated = yield(data[token.to_s])
        data[token.to_s] = updated
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

    JSON.parse(File.read(path))
  rescue JSON::ParserError
    {}
  end

  def write_bucket(key, data)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "tickets-#{key}.json")
    tmp = "#{path}.#{SecureRandom.hex(8)}.tmp"
    File.write(tmp, JSON.generate(data))
    File.rename(tmp, path)
  end
end
