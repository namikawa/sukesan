# frozen_string_literal: true

# 設定フォームの入力整形・検証ヘルパ。
module SettingsParamsHelpers
  def valid_hhmm?(value)
    value.to_s.match?(/\A([01]\d|2[0-3]):[0-5]\d\z/)
  end

  # 設定フォームの入力を SettingsStore.save の引数形に整える。
  def settings_params
    {
      business_start: params[:business_start].to_s,
      business_end: params[:business_end].to_s,
      business_days: business_days_param,
      lunch_start: params[:lunch_start].to_s,
      lunch_end: params[:lunch_end].to_s,
      lunch_minutes: params[:lunch_minutes].to_i
    }
  end

  def business_days_param
    Array(params[:business_days]).map(&:to_i).grep(0..6).uniq.sort
  end

  def settings_valid?(values)
    valid_hhmm?(values[:business_start]) && valid_hhmm?(values[:business_end]) &&
      values[:business_start] < values[:business_end] &&
      valid_hhmm?(values[:lunch_start]) && valid_hhmm?(values[:lunch_end]) &&
      values[:lunch_start] < values[:lunch_end] &&
      values[:lunch_minutes] >= 0
  end
end
