# frozen_string_literal: true

# 設定フォームの入力整形・検証ヘルパ。
module SettingsParamsHelpers
  def valid_hhmm?(value)
    value.to_s.match?(/\A([01]\d|2[0-3]):[0-5]\d\z/)
  end

  # 同期で取得する日数（日先・Google/Outlook 共通）の許容範囲。
  SYNC_WINDOW_DAYS_RANGE = (1..365)

  # スケジュール設定フォーム（/settings）の入力を SettingsStore.save の引数形に整える。
  def settings_params
    {
      business_start: str_param(:business_start),
      business_end: str_param(:business_end),
      business_days: business_days_param,
      lunch_start: str_param(:lunch_start),
      lunch_end: str_param(:lunch_end),
      lunch_minutes: int_param(:lunch_minutes)
    }
  end

  def sync_window_days_valid?(days)
    SYNC_WINDOW_DAYS_RANGE.cover?(days)
  end

  def str_param(key)
    params[key].to_s
  end

  def int_param(key)
    params[key].to_i
  end

  def business_days_param
    Array(params[:business_days]).map(&:to_i).grep(0..6).uniq.sort
  end

  def settings_valid?(values)
    business_hours_valid?(values) && lunch_valid?(values)
  end

  def business_hours_valid?(values)
    valid_hhmm?(values[:business_start]) && valid_hhmm?(values[:business_end]) &&
      values[:business_start] < values[:business_end]
  end

  def lunch_valid?(values)
    valid_hhmm?(values[:lunch_start]) && valid_hhmm?(values[:lunch_end]) &&
      values[:lunch_start] < values[:lunch_end] && values[:lunch_minutes] >= 0
  end
end
