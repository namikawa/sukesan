# frozen_string_literal: true

RSpec.describe FreeSlotFinder do
  let(:date) { Date.new(2026, 6, 22) }

  # 営業時間内のローカル時刻で予定を作るヘルパ。
  def busy(start_h, start_m, end_h, end_m, all_day: false)
    Event.new(
      source: "google",
      title: "予定",
      starts_at: Time.local(2026, 6, 22, start_h, start_m),
      ends_at: Time.local(2026, 6, 22, end_h, end_m),
      all_day: all_day
    )
  end

  describe "#find" do
    it "予定がなければ営業時間内を30分刻みで埋める" do
      finder = described_class.new(business_start: "09:00", business_end: "11:00")

      slots = finder.find(date: date, duration_minutes: 60, busy_events: [])

      # 60分枠を30分刻みで: 9:00-10:00, 9:30-10:30, 10:00-11:00
      expect(slots.map { |s| s.starts_at.strftime("%H:%M") }).to eq(["09:00", "09:30", "10:00"])
    end

    it "既存の予定と重なる候補は除外する" do
      finder = described_class.new(business_start: "09:00", business_end: "11:00")

      slots = finder.find(date: date, duration_minutes: 60, busy_events: [busy(9, 30, 10, 0)])

      # 9:00-10:00 / 9:30-10:30 は 9:30-10:00 と重なるため除外、10:00-11:00 のみ残る
      expect(slots.map { |s| s.starts_at.strftime("%H:%M") }).to eq(["10:00"])
    end

    it "終日予定は空き扱いとし、ブロックしない" do
      finder = described_class.new(business_start: "09:00", business_end: "11:00")

      slots = finder.find(date: date, duration_minutes: 60, busy_events: [busy(0, 0, 0, 0, all_day: true)])

      # 終日予定があっても時間指定の予定がなければ通常どおり候補が出る
      expect(slots.map { |s| s.starts_at.strftime("%H:%M") }).to eq(["09:00", "09:30", "10:00"])
    end

    it "終日予定と時間指定予定が混在する場合は時間指定のみブロックする" do
      finder = described_class.new(business_start: "09:00", business_end: "11:00")

      slots = finder.find(
        date: date, duration_minutes: 60,
        busy_events: [busy(0, 0, 0, 0, all_day: true), busy(9, 30, 10, 0)]
      )

      expect(slots.map { |s| s.starts_at.strftime("%H:%M") }).to eq(["10:00"])
    end

    it "所要時間が営業時間に収まらなければ候補なし" do
      finder = described_class.new(business_start: "09:00", business_end: "10:00")

      slots = finder.find(date: date, duration_minutes: 90, busy_events: [])

      expect(slots).to be_empty
    end

    it "所要時間が0以下なら候補なし" do
      finder = described_class.new(business_start: "09:00", business_end: "18:00")

      expect(finder.find(date: date, duration_minutes: 0, busy_events: [])).to be_empty
    end

    it "調整可能な曜日でなければ候補なし" do
      # 2026-06-22 は月曜（wday=1）。火〜日のみ許可なら候補は出ない。
      finder = described_class.new(business_start: "09:00", business_end: "18:00", business_days: [2, 3, 4, 5, 6, 0])

      expect(finder.find(date: date, duration_minutes: 60, busy_events: [])).to be_empty
    end

    it "調整可能な曜日なら候補が出る" do
      finder = described_class.new(business_start: "09:00", business_end: "11:00", business_days: [1])

      slots = finder.find(date: date, duration_minutes: 60, busy_events: [])

      expect(slots.map { |s| s.starts_at.strftime("%H:%M") }).to eq(["09:00", "09:30", "10:00"])
    end
  end

  describe "ランチタイム保護" do
    it "11:00〜14:00 に十分余裕があれば lunch フラグは立たない" do
      finder = described_class.new(business_start: "11:00", business_end: "14:00")

      slots = finder.find(date: date, duration_minutes: 60, busy_events: [])

      # どの枠を入れても連続1時間以上の空きが残るため警告なし
      expect(slots).not_to be_empty
      expect(slots.map(&:lunch)).to all(be(false))
    end

    it "昼の連続1時間を潰す枠には lunch フラグを立てる" do
      finder = described_class.new(business_start: "11:00", business_end: "14:00")
      # 11:00〜13:00 が埋まっており、残りの空きは 13:00〜14:00 の1時間のみ
      slots = finder.find(date: date, duration_minutes: 60, busy_events: [busy(11, 0, 13, 0)])

      flagged = slots.select(&:lunch).map { |s| s.starts_at.strftime("%H:%M") }
      expect(flagged).to eq(["13:00"])
    end

    it "11:00〜14:00 の外の枠には lunch フラグを立てない" do
      finder = described_class.new(business_start: "09:00", business_end: "11:00")

      slots = finder.find(date: date, duration_minutes: 60, busy_events: [])

      expect(slots.map(&:lunch)).to all(be(false))
    end
  end
end
