# frozen_string_literal: true

RSpec.describe AvailabilitySearch do
  let(:settings) do
    {
      "business_start" => "09:00", "business_end" => "18:00", "business_days" => [1, 2, 3, 4, 5],
      "lunch_start" => "11:00", "lunch_end" => "14:00", "lunch_minutes" => 60
    }
  end
  # list_events(time_min:, time_max:) に空イベントで応答するスタブ（外部 API を呼ばない）。
  let(:calendar_client) { double(list_events: []) }
  subject(:search) { described_class.new(settings: settings, calendar_client: calendar_client) }

  describe "#search" do
    it "営業日ごとに空き候補を返す（2026-06-22 は月曜）" do
      result = search.search(start_date: "2026-06-22", end_date: "2026-06-22", duration_minutes: 30)
      expect(result.searched).to be(true)
      expect(result.capped).to be(false)
      expect(result.days.map(&:first)).to eq([Date.new(2026, 6, 22)])
      expect(result.days.first.last).not_to be_empty
    end

    it "不正な日付は空の結果を返す" do
      result = search.search(start_date: "bad", end_date: "x", duration_minutes: 30)
      expect(result.searched).to be(true)
      expect(result.days).to eq([])
    end

    it "ISO8601 でない日付（例: 2026/06/22）は空の結果を返す" do
      result = search.search(start_date: "2026/06/22", end_date: "2026/06/22", duration_minutes: 30)
      expect(result.searched).to be(true)
      expect(result.days).to eq([])
    end

    it "15 の倍数でない所要時間は空の結果を返す" do
      result = search.search(start_date: "2026-06-22", end_date: "2026-06-22", duration_minutes: 20)
      expect(result.searched).to be(true)
      expect(result.days).to eq([])
    end

    it "MAX_BUSINESS_DAYS を超える期間は capped=true で打ち切る" do
      result = search.search(start_date: "2026-06-22", end_date: "2026-12-31", duration_minutes: 30)
      expect(result.capped).to be(true)
      expect(result.days.size).to eq(described_class::MAX_BUSINESS_DAYS)
    end
  end

  describe "#slot_available?" do
    it "候補に存在する枠は true" do
      starts = Time.iso8601("2026-06-22T09:00:00+09:00")
      ends = Time.iso8601("2026-06-22T09:30:00+09:00")
      expect(search.slot_available?(starts, ends)).to be(true)
    end

    it "候補に無い枠（営業時間外）は false" do
      starts = Time.iso8601("2026-06-22T03:00:00+09:00")
      ends = Time.iso8601("2026-06-22T04:00:00+09:00")
      expect(search.slot_available?(starts, ends)).to be(false)
    end

    it "開始 >= 終了は false" do
      t = Time.iso8601("2026-06-22T09:00:00+09:00")
      expect(search.slot_available?(t, t)).to be(false)
    end

    it "15 の倍数でない長さ（例: 1分）は false" do
      starts = Time.iso8601("2026-06-22T09:00:00+09:00")
      ends = Time.iso8601("2026-06-22T09:01:00+09:00")
      expect(search.slot_available?(starts, ends)).to be(false)
    end

    it "カレンダーが既に埋まっている枠は false（先行予約を検知）" do
      busy = Event.new(
        source: "google", title: "予定",
        starts_at: Time.local(2026, 6, 22, 9, 0), ends_at: Time.local(2026, 6, 22, 9, 30), all_day: false
      )
      booked = described_class.new(settings: settings, calendar_client: double(list_events: [busy]))
      starts = Time.iso8601("2026-06-22T09:00:00+09:00")
      ends = Time.iso8601("2026-06-22T09:30:00+09:00")
      expect(booked.slot_available?(starts, ends)).to be(false)
    end
  end
end
