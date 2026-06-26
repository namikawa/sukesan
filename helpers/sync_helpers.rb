# frozen_string_literal: true

# Outlook 同期（管理者専用）を支えるヘルパ。
module SyncHelpers
  # チェック時のパラメータから取得期間 [time_min, time_max] とエラーメッセージを返す。
  # 戻り値: [window(=[min,max]) または nil, エラーメッセージ または nil]
  # 日数モードでは入力日数を既定値として保存する（前回値を覚える）。
  def resolve_sync_window(params)
    if params[:range_mode] == "range"
      window = range_window(params[:start_date], params[:end_date])
      window ? [window, nil] : [nil, "日付範囲が正しくありません（開始 ≤ 終了・最大 #{MAX_SYNC_RANGE_DAYS} 日）。"]
    else
      days = params[:sync_window_days].to_i
      max_days = SettingsParamsHelpers::SYNC_WINDOW_DAYS_RANGE.max
      return [nil, "取得日数は 1〜#{max_days} 日で入力してください。"] unless sync_window_days_valid?(days)

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

  def synced_keys
    session[:synced_keys] ||= []
  end
end
