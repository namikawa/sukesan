# frozen_string_literal: true

require "time"

# チケットの状態判定。保存内容（ハッシュ）に対する純粋ロジックで、永続化方式（file/firestore）に依存しない。
# 発行から TTL_SECONDS（24時間）経過、または used/revoked で無効。
module TicketStatus
  module_function

  TTL_SECONDS = 24 * 60 * 60

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
end
