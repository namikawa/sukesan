# frozen_string_literal: true

require_relative "settings_params_helpers"

# Outlook 同期（管理者専用）を支えるヘルパ。
module SyncHelpers
  # 日付範囲指定で許可する最大日数（開始〜終了の差）。日数指定の上限から導出し、二重定義を避ける。
  MAX_SYNC_RANGE_DAYS = SettingsParamsHelpers::SYNC_WINDOW_DAYS_RANGE.max

  # チェック時のパラメータから取得期間 [time_min, time_max] とエラーメッセージを返す。
  # 戻り値: [window(=[min,max]) または nil, エラーメッセージ または nil]
  # 日数モードでは入力日数を既定値として保存する（前回値を覚える）。
  def resolve_sync_window(params)
    if params[:range_mode] == "range"
      window = range_window(params[:start_date], params[:end_date])
      window ? [window, nil] : [nil, "日付範囲が正しくありません（開始 ≤ 終了・最大 #{MAX_SYNC_RANGE_DAYS} 日）。"]
    else
      days = params[:sync_window_days].to_i
      return [nil, "取得日数は 1〜#{MAX_SYNC_RANGE_DAYS} 日で入力してください。"] unless sync_window_days_valid?(days)

      SettingsStore.save(sync_window_days: days) # 日数モードのチェック時は既定値として保存
      [days_window(days), nil]
    end
  end

  # 当日 0:00 から days 日先までの期間。
  def days_window(days)
    start = start_of_today
    [start, start + (days * 86_400)]
  end

  # 開始日〜終了日（終了日を含む）の期間。不正（非 ISO8601・開始>終了・最大日数超）なら nil。
  def range_window(start_str, end_str)
    start_date = Date.iso8601(start_str.to_s)
    end_date = Date.iso8601(end_str.to_s)
    return nil if end_date < start_date || (end_date - start_date).to_i > MAX_SYNC_RANGE_DAYS

    [local_midnight(start_date), local_midnight(end_date) + 86_400]
  rescue ArgumentError
    nil
  end

  def start_of_today
    now = Time.now
    Time.local(now.year, now.month, now.day, 0, 0)
  end

  def local_midnight(date)
    Time.local(date.year, date.month, date.day, 0, 0)
  end

  # チェック結果（差分そのもの）はセッションに載せない。取得範囲とテストモードだけを
  # 署名 Cookie に収まる最小限の形で保存し、差分は表示・反映時に都度再計算する（常に最新・ステールなし）。
  def store_sync_window(window, test_mode:)
    min, max = window
    session[:sync_window] = { "min" => min.iso8601, "max" => max.iso8601, "test" => test_mode }
  end

  # セッションに保存した取得範囲を [time_min, time_max] で返す（無効・未保存なら nil）。
  def current_sync_window
    saved = session[:sync_window]
    return nil unless saved

    [Time.iso8601(saved["min"]), Time.iso8601(saved["max"])]
  rescue ArgumentError
    nil
  end

  def sync_test_mode?
    session.dig(:sync_window, "test") == true
  end

  def clear_sync_window
    session.delete(:sync_window)
  end

  # 取得範囲について Google・Outlook を取得し、Outlook 側にのみ存在するイベント（同期候補）を返す。
  # どちらかのトークンが使えない（未連携・refresh 失敗）場合は nil を返す（呼び出し側で案内を表示する）。
  def compute_outlook_only(window)
    google = google_token
    outlook = microsoft_token
    return nil if google.nil? || outlook.nil?

    time_min, time_max = window
    google_events = GoogleCalendarClient.new(google).list_events(time_min: time_min, time_max: time_max)
    outlook_events = OutlookCalendarClient.new(outlook).list_events(time_min: time_min, time_max: time_max)
    EventDiffer.outlook_only(google_events: google_events, outlook_events: outlook_events)
  end
end
