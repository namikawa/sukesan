# frozen_string_literal: true

require "time"

# 指定日の営業時間内で、指定した所要時間ぶんの空き時間候補を算出する。
# 既存の予定（busy_events）と重ならない開始時刻を step_minutes 刻みで列挙する。
#
# あわせて、昼休憩（LUNCH_START〜LUNCH_END の間に連続1時間）を確保するため、
# 「その枠を入れると昼休憩用の連続空きが1時間未満になる」候補には lunch フラグを立てる。
# 候補自体は残す（急ぎの予定のために選択できる）が、UI 側で控えめに表示する想定。
class FreeSlotFinder
  Slot = Struct.new(:starts_at, :ends_at, :lunch, keyword_init: true)

  LUNCH_START = "11:00"
  LUNCH_END = "14:00"
  LUNCH_MIN_SECONDS = 60 * 60

  def initialize(business_start:, business_end:, business_days: (0..6).to_a, step_minutes: 30)
    @business_start = business_start
    @business_end = business_end
    @business_days = business_days
    @step_minutes = step_minutes
  end

  # date: Date、duration_minutes: Integer、busy_events: Array<Event>
  def find(date:, duration_minutes:, busy_events:)
    return [] if duration_minutes <= 0
    return [] unless @business_days.include?(date.wday)

    busy = busy_intervals(busy_events)
    slots = build_slots(date, duration_minutes * 60, busy)
    flag_lunch(slots, date, busy)
    slots
  end

  private

  def build_slots(date, duration, busy)
    window_start = at(date, @business_start)
    window_end = at(date, @business_end)
    step = @step_minutes * 60

    slots = []
    start = window_start
    while start + duration <= window_end
      finish = start + duration
      slots << Slot.new(starts_at: start, ends_at: finish, lunch: false) unless overlap?(start, finish, busy)
      start += step
    end
    slots
  end

  # 昼休憩の連続1時間を確保できなくなる候補に lunch フラグを立てる。
  def flag_lunch(slots, date, busy)
    lunch_start = at(date, LUNCH_START)
    lunch_end = at(date, LUNCH_END)

    slots.each do |slot|
      next unless slot.starts_at < lunch_end && lunch_start < slot.ends_at

      with_slot = busy + [[slot.starts_at, slot.ends_at]]
      slot.lunch = max_free_seconds(lunch_start, lunch_end, with_slot) < LUNCH_MIN_SECONDS
    end
  end

  # 窓 [window_start, window_end) 内で、busy を除いた連続空き時間の最大秒数。
  def max_free_seconds(window_start, window_end, busy)
    intervals = clip_intervals(busy, window_start, window_end)
    longest_gap(intervals, window_start, window_end)
  end

  # busy 区間を窓内にクリップし、開始順に並べる。
  def clip_intervals(busy, window_start, window_end)
    busy.map { |s, e| [[s, window_start].max, [e, window_end].min] }
        .select { |s, e| s < e }
        .sort_by(&:first)
  end

  def longest_gap(intervals, window_start, window_end)
    max = 0
    cursor = window_start
    intervals.each do |s, e|
      max = [max, s - cursor].max
      cursor = e if e > cursor
    end
    [max, window_end - cursor].max
  end

  def at(date, hhmm)
    hour, min = hhmm.split(":").map(&:to_i)
    Time.local(date.year, date.month, date.day, hour, min)
  end

  # 終日予定は Google の既定では「空き時間」扱いのため、時間を専有しない。
  # よって時間指定の予定だけを埋まっている時間帯として扱う。
  def busy_intervals(events)
    events.reject(&:all_day).map do |event|
      [event.starts_at, event.ends_at || event.starts_at]
    end
  end

  def overlap?(start, finish, busy)
    busy.any? { |b_start, b_end| start < b_end && b_start < finish }
  end
end
