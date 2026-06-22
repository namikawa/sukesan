# frozen_string_literal: true

require "date"
require "time"
require_relative "free_slot_finder"

# 管理者カレンダーの空き時間検索ロジック。
#
# Web レイヤから切り離した素の Ruby クラスとして、設定（settings ハッシュ）と
# カレンダークライアント（list_events(time_min:, time_max:) に応答するもの）を受け取り、
# 期間内の空き候補の算出と、送信された枠の実在チェックを行う。
class AvailabilitySearch
  # 一度に表示する最大営業日数。
  MAX_BUSINESS_DAYS = 5
  # 営業日探索の最大走査日数（DoS 防止）。
  MAX_SCAN_DAYS = 366
  # 所要時間の刻み（分）。許可するのは「正の値かつこの倍数」のみ（UI の min/step と一致）。
  DURATION_STEP_MINUTES = 15

  # 検索結果。days = [[Date, [slots]], ...]
  Result = Struct.new(:searched, :capped, :days, keyword_init: true)

  # calendar_client は list_events(time_min:, time_max:) に応答するもの（例: GoogleCalendarClient）。
  def initialize(settings:, calendar_client:)
    @settings = settings
    @calendar_client = calendar_client
  end

  # 期間（YYYY-MM-DD 文字列）と必要分数から、日付ごとの空き候補を返す。
  # 日付が不正（非 ISO8601）・所要時間が不正な場合は空の結果（searched: true）を返す。
  def search(start_date:, end_date:, duration_minutes:)
    return empty_result unless valid_duration?(duration_minutes)

    dates, capped = business_dates_in_range(Date.iso8601(start_date.to_s), Date.iso8601(end_date.to_s))
    days = dates.empty? ? [] : slots_by_date(dates, duration_minutes)
    Result.new(searched: true, capped: capped, days: days)
  rescue ArgumentError
    empty_result
  end

  # 送信された時間帯が、サーバ側で再計算した当日の空き候補に実在するか。
  # クライアント値を信用せず、営業時間・曜日・空き・刻み・所要時間の整合をここで担保する。
  def slot_available?(starts_at, ends_at)
    return false if ends_at <= starts_at

    minutes = ((ends_at - starts_at) / 60).to_i
    return false unless valid_duration?(minutes)

    date = starts_at.getlocal.to_date
    candidate_slots(date, minutes).any? do |slot|
      slot.starts_at.to_i == starts_at.to_i && slot.ends_at.to_i == ends_at.to_i
    end
  end

  private

  # 所要時間（分）が許可ポリシー内か。正かつ DURATION_STEP_MINUTES の倍数のみ許可。
  # 過大な長さは営業時間内に候補が存在しないため自然に弾かれる。
  def valid_duration?(minutes)
    minutes.is_a?(Integer) && minutes.positive? && (minutes % DURATION_STEP_MINUTES).zero?
  end

  def empty_result
    Result.new(searched: true, capped: false, days: [])
  end

  # 開始日から営業日を最大 MAX_BUSINESS_DAYS 件まで集める。
  # 全範囲を走査せず、上限件数 +1 を見つけた時点で打ち切る（DoS 防止）。
  def business_dates_in_range(start_date, end_date)
    dates = []
    date = start_date
    scanned = 0
    while date <= end_date && scanned < MAX_SCAN_DAYS
      dates << date if @settings["business_days"].include?(date.wday)
      return [dates.first(MAX_BUSINESS_DAYS), true] if dates.size > MAX_BUSINESS_DAYS

      date += 1
      scanned += 1
    end
    [dates, false]
  end

  # 範囲全体のイベントを 1 回で取得し、各日の空き候補を算出する（日ごとの API 呼び出しを避ける）。
  def slots_by_date(dates, duration_minutes)
    events = fetch_events(dates.first, dates.last)
    dates.map { |d| [d, finder.find(date: d, duration_minutes: duration_minutes, busy_events: events)] }
  end

  def candidate_slots(date, duration_minutes)
    finder.find(date: date, duration_minutes: duration_minutes, busy_events: fetch_events(date, date))
  end

  def finder
    @finder ||= FreeSlotFinder.new(
      business_start: @settings["business_start"],
      business_end: @settings["business_end"],
      business_days: @settings["business_days"],
      lunch_start: @settings["lunch_start"],
      lunch_end: @settings["lunch_end"],
      lunch_minutes: @settings["lunch_minutes"]
    )
  end

  def fetch_events(first_date, last_date)
    span_start = Time.local(first_date.year, first_date.month, first_date.day, 0, 0)
    span_end = Time.local(last_date.year, last_date.month, last_date.day, 0, 0) + 86_400
    @calendar_client.list_events(time_min: span_start, time_max: span_end)
  end
end
