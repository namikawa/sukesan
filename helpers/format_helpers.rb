# frozen_string_literal: true

# 画面表示用の整形ヘルパ。
module FormatHelpers
  # 発行済みワンタイム URL の一覧表示に使うステータス文言。
  TICKET_STATUS_LABELS = {
    "active" => "有効", "used" => "使用済み", "expired" => "期限切れ", "revoked" => "無効化",
    "held" => "仮押さえ中", "cancelled" => "キャンセル", "invalid" => "不正"
  }.freeze

  # 曜日の表示順とラベル（Ruby の wday: 0=日〜6=土）。月曜始まりで表示する。
  WEEKDAY_LABELS = { 0 => "日", 1 => "月", 2 => "火", 3 => "水", 4 => "木", 5 => "金", 6 => "土" }.freeze
  WEEKDAY_ORDER = [1, 2, 3, 4, 5, 6, 0].freeze

  # パーシャル（views/_*.erb）をレイアウト無しで描画する。
  # 描画結果は HTML のため、呼び出し側は <%== %>（エスケープ無し）で埋め込む。
  def partial(name, locals = {})
    erb :"_#{name}", layout: false, locals: locals
  end

  # flash（操作結果の通知）と flash_alert（入力・状態エラーの警告）の表示ブロック。
  # type は flash 通知の色（info / success / danger）。
  def flash_messages(type: "info")
    partial(:flash, type: type)
  end

  # ページ共通ヘッダ（ロゴ・タイトル・サブタイトル）。右側には logout: true でログアウトボタン、
  # admin_link: true で「管理者の方はこちら」リンクを表示する（両方 false なら右側なし）。
  def page_header(title:, subtitle: "SUKESAN", logout: false, admin_link: false)
    partial(:page_header, title: title, subtitle: subtitle, logout: logout, admin_link: admin_link)
  end

  # 発行したワンタイム URL（依頼者へ渡す調整ページの絶対 URL）。
  def ticket_url(token)
    "#{base_url}/t/#{token}"
  end

  def ticket_status_label(ticket)
    TICKET_STATUS_LABELS.fetch(TicketStore.status(ticket), "不明")
  end

  # 保存された ISO8601 文字列を表示用の日時に整える。
  def format_iso(value)
    format_dt(Time.iso8601(value.to_s))
  rescue ArgumentError
    ""
  end

  # 予約枠（開始〜終了）の表示。同日なら終了側の日付を省略する。
  def format_slot_range(start_iso, end_iso)
    starts = Time.iso8601(start_iso.to_s).getlocal
    ends = Time.iso8601(end_iso.to_s).getlocal
    if starts.to_date == ends.to_date
      "#{format_dt(starts)}〜#{format_time(ends)}"
    else
      "#{format_dt(starts)} 〜 #{format_dt(ends)}"
    end
  rescue ArgumentError
    ""
  end

  def format_dt(time, all_day: false)
    return "" if time.nil?

    local = time.getlocal
    all_day ? local.strftime("%Y-%m-%d") : local.strftime("%Y-%m-%d %H:%M")
  end

  def format_time(time)
    time.getlocal.strftime("%H:%M")
  end

  def format_date_label(date)
    "#{date.month}/#{date.day}（#{WEEKDAY_LABELS[date.wday]}）"
  end
end
