# frozen_string_literal: true

require "time"

# チケットの状態判定。保存内容（ハッシュ）に対する純粋ロジックで、永続化方式（file/firestore）に依存しない。
# - active（未使用）: 発行（created_at）から TTL_SECONDS（24時間）で期限切れ
# - held（仮押さえ中）: 仮押さえ（held_at）から HOLD_TTL_SECONDS（7日）で期限切れ
# - used / revoked / cancelled は終端状態（時間経過で変化しない）
module TicketStatus
  module_function

  TTL_SECONDS = 24 * 60 * 60
  # 仮押さえ後に決定画面を操作できる期間（仮押さえ実行時から）。
  HOLD_TTL_SECONDS = 7 * 24 * 60 * 60

  TERMINAL_STATUSES = %w[used revoked cancelled].freeze

  # 保存・遷移で扱う正規のステータス集合。これ以外の値（データ破損・改ざん）は "invalid" とみなす。
  # active はハッシュ上では status キー未設定（nil）または "active" のどちらでも表す。
  VALID_STATUSES = (TERMINAL_STATUSES + %w[held active]).freeze

  def expired?(ticket, now: Time.now)
    if ticket["status"] == "held"
      Time.iso8601(ticket["held_at"].to_s) + HOLD_TTL_SECONDS < now
    else
      Time.iso8601(ticket["created_at"].to_s) + TTL_SECONDS < now
    end
  rescue ArgumentError
    true
  end

  # 表示用ステータス: used / revoked / cancelled / expired / held / active / invalid
  # 未知の status 値（データ破損・改ざん）は fail-closed で "invalid" を返し、active?/held? を
  # false にして操作（予約・仮押さえ・決定）を一切許さない。
  def status(ticket, now: Time.now)
    raw = ticket["status"]
    return "invalid" unless raw.nil? || VALID_STATUSES.include?(raw)
    return raw if TERMINAL_STATUSES.include?(raw)
    return "expired" if expired?(ticket, now: now)

    raw == "held" ? "held" : "active"
  end

  def active?(ticket, now: Time.now)
    !ticket.nil? && status(ticket, now: now) == "active"
  end

  # 仮押さえ中（決定・削除の操作が可能な状態）か。
  def held?(ticket, now: Time.now)
    !ticket.nil? && status(ticket, now: now) == "held"
  end
end
