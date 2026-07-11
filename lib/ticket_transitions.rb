# frozen_string_literal: true

require "time"
require_relative "ticket_status"

# チケットの状態遷移（純粋ロジック）。現在のチケット内容から遷移後の内容を計算する。
# 永続化と排他（file=flock / firestore=トランザクション）は各バックエンドが担い、
# ここは「遷移できるかの判定」と「遷移後ハッシュの組み立て」だけを持つ（両バックエンドで共有）。
#
# 戻り値の規約: 遷移できる場合は [遷移後のチケット, 呼び出し側へ返す値]、できない場合は nil。
module TicketTransitions
  module_function

  # 予約（現行のカレンダー登録）: active → used。
  def use(ticket, attrs:, now:)
    return nil unless TicketStatus.active?(ticket, now: now)

    [ticket.merge(attrs).merge("status" => "used", "used_at" => now.iso8601), true]
  end

  # 予約失敗時の巻き戻し: used / held → active（保存した入力値・仮押さえ関連キーも消す）。
  # 遷移元を限定し、終端（revoked/cancelled）や不正状態からは戻せないようにする。
  # - used: 通常予約（use! 後にカレンダー登録失敗）の巻き戻し（BookingService）。
  # - held: 仮押さえイベントの作成が途中失敗したときの巻き戻し（HoldService.rollback_created）。
  REACTIVATABLE_FROM = %w[used held].freeze

  def reactivate(ticket)
    return nil unless REACTIVATABLE_FROM.include?(ticket["status"])

    updated = ticket.except("status", "used_at", "requester", "title", "slot_start", "slot_end",
                            "attendees", "holds", "held_at", "holder_key")
                    .merge("status" => "active")
    [updated, true]
  end

  # 仮押さえ: active → held。attrs には requester/title/holds/holder_key を渡す。
  def hold(ticket, attrs:, now:)
    return nil unless TicketStatus.active?(ticket, now: now)

    [ticket.merge(attrs).merge("status" => "held", "held_at" => now.iso8601), true]
  end

  # 仮押さえから 1 件を選んで確定: held → used。選択スロットの日時を確定内容として記録し、
  # 確定前の holds（呼び出し側がイベントの件名更新・削除に使う）を返す。
  def confirm_hold(ticket, slot_start:, attrs:, now:)
    chosen = find_hold(ticket, slot_start, now: now)
    return nil if chosen.nil?

    updated = ticket.except("holds", "holder_key").merge(attrs)
                    .merge("status" => "used", "used_at" => now.iso8601,
                           "slot_start" => chosen["slot_start"], "slot_end" => chosen["slot_end"])
    [updated, ticket["holds"]]
  end

  # 仮押さえから 1 件を取り除く。最後の 1 件を取り除いた場合は cancelled（終了）へ遷移する。
  # 取り除いた hold エントリを返す。
  def remove_hold(ticket, slot_start:, now:)
    removed = find_hold(ticket, slot_start, now: now)
    return nil if removed.nil?

    rest = ticket["holds"] - [removed]
    updated = if rest.empty?
                ticket.except("holds", "holder_key").merge("status" => "cancelled")
              else
                ticket.merge("holds" => rest)
              end
    [updated, removed]
  end

  # 仮押さえをすべて取りやめて終了: held → cancelled。取りやめた holds を返す。
  def cancel_hold(ticket, now:)
    return nil unless TicketStatus.held?(ticket, now: now)

    [ticket.except("holds", "holder_key").merge("status" => "cancelled"), ticket["holds"]]
  end

  # 管理者による無効化: active または held → revoked。仮押さえ中だった場合の残イベント掃除用に、
  # 遷移前のチケットを返す。
  def revoke(ticket, now:)
    return nil unless %w[active held].include?(TicketStatus.status(ticket, now: now))

    [ticket.except("holds", "holder_key").merge("status" => "revoked"), ticket]
  end

  # held のチケットから slot_start（ISO8601 文字列）が一致する hold エントリを探す。
  # クライアントにはイベント ID を渡さず、スロット開始時刻をキーとして照合するための関数。
  def find_hold(ticket, slot_start, now:)
    return nil unless TicketStatus.held?(ticket, now: now)

    Array(ticket["holds"]).find { |hold| hold["slot_start"] == slot_start }
  end
end
