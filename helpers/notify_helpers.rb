# frozen_string_literal: true

# ゲスト操作・API 操作を管理者の Slack へ知らせる通知文の組み立て。
#
# 同じ操作でも経路（画面 / API）で本文が「（API 経由: ラベル）」の有無だけ違うため、via:（nil なら
# 画面経由）で差分を表現し、本文の二重定義を防ぐ。通知の送信可否・失敗時の扱いは SlackNotifier の責務。
# 管理者宛のため依頼者名・件名は含めてよいが、生 token・チケット URL は載せない（既存方針）。
module NotifyHelpers
  # 予約が登録された（POST /schedule・POST /api/v1/bookings）。
  def notify_booking_created(requester:, title:, slot_label:, via: nil)
    SlackNotifier.notify(
      "新規のスケジュールが追加されました#{notify_via_suffix(via)}\n依頼者: #{requester}\n件名: #{title}\n日時: #{slot_label}"
    )
  end

  # 予約が取り消された（POST /api/v1/bookings/:id/cancel）。note には削除できなかった予定の注意書き。
  def notify_booking_cancelled(requester:, title:, slot_label:, note:, via: nil)
    SlackNotifier.notify(
      "予約が取り消されました#{notify_via_suffix(via)}\n依頼者: #{requester}\n件名: #{title}\n日時: #{slot_label}#{note}"
    )
  end

  # 仮押さえが作成された（POST /hold・POST /api/v1/holds）。件数を見出しの括弧に併記する都合で、
  # 経由の表記も同じ括弧の中へ入れる（「（3 件・API 経由: bot）」）。
  def notify_hold_created(slots:, requester:, title:, via: nil)
    suffix = via.nil? ? "" : "・API 経由: #{via}"
    SlackNotifier.notify(
      "仮押さえが入りました（#{slots.size} 件#{suffix}）\n依頼者: #{requester}\n件名: #{title}\n" \
      "候補日時:\n#{notify_slot_lines(slots)}"
    )
  end

  # 仮押さえから 1 件に決定された（POST /hold/confirm・POST /api/v1/holds/:id/confirm）。
  def notify_hold_confirmed(requester:, title:, slot_label:, via: nil)
    SlackNotifier.notify(
      "仮押さえから 1 件に決定しました#{notify_via_suffix(via)}\n依頼者: #{requester}\n件名: #{title}\n日時: #{slot_label}"
    )
  end

  # 仮押さえがすべて取りやめられた（POST /hold/cancel・POST /api/v1/holds/:id/cancel）。
  def notify_hold_cancelled(holds:, requester:, title:, via: nil)
    SlackNotifier.notify(
      "仮押さえがすべて取りやめられました#{notify_via_suffix(via)}\n依頼者: #{requester}\n件名: #{title}\n" \
      "取りやめた候補:\n#{notify_hold_lines(holds)}"
    )
  end

  # 経由の併記。画面経由（via が nil）のときは何も付けない。
  def notify_via_suffix(via)
    via.nil? ? "" : "（API 経由: #{via}）"
  end

  # 候補日時の箇条書き（入力は解釈済みの [[Time, Time], ...]）。仮押さえの作成で使う。
  def notify_slot_lines(slots)
    slots.map { |starts_at, ends_at| "・#{slack_slot_label(starts_at.iso8601, ends_at.iso8601)}" }.join("\n")
  end

  # 候補日時の箇条書き（入力はチケットに保存した holds ＝ ISO8601 文字列）。全取りやめで使う。
  # notify_slot_lines とは入力の型が別物なので、無理に 1 つへまとめない。
  def notify_hold_lines(holds)
    Array(holds).map { |hold| "・#{slack_slot_label(hold['slot_start'], hold['slot_end'])}" }.join("\n")
  end
end
