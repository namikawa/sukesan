# frozen_string_literal: true

# スケジュール調整フォームの入力解釈・既定値まわりのヘルパ。
module ScheduleHelpers
  # 空き時間検索サービスを、管理者の Google カレンダーに接続して組み立てる。
  def availability_search(settings)
    AvailabilitySearch.new(settings: settings, calendar_client: GoogleCalendarClient.new(google_token))
  end

  # 翌日以降で、調整可能な曜日（business_days）に該当する最初の日付。
  # 曜日が未設定なら単純に翌日を返す。
  def next_business_day(business_days)
    date = Date.today + 1
    return date if business_days.empty?

    date += 1 until business_days.include?(date.wday)
    date
  end

  # "開始ISO8601/終了ISO8601" を [Time, Time] に厳格パースする。不正なら [nil, nil]。
  def parse_slot(raw)
    starts_iso, ends_iso = raw.to_s.split("/", 2)
    return [nil, nil] if starts_iso.nil? || ends_iso.nil?

    [Time.iso8601(starts_iso), Time.iso8601(ends_iso)]
  rescue ArgumentError
    [nil, nil]
  end
end
