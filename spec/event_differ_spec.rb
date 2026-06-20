# frozen_string_literal: true

RSpec.describe EventDiffer do
  def event(source:, title:, start:)
    Event.new(
      source: source,
      title: title,
      starts_at: Time.parse(start),
      ends_at: Time.parse(start) + 3600,
      all_day: false
    )
  end

  describe ".outlook_only" do
    it "Google 側に同じ内容のイベントがあれば除外する" do
      google = [event(source: "google", title: "定例MTG", start: "2026-06-20T10:00:00+09:00")]
      outlook = [event(source: "outlook", title: "定例MTG", start: "2026-06-20T10:00:00+09:00")]

      expect(described_class.outlook_only(google_events: google, outlook_events: outlook)).to be_empty
    end

    it "Outlook 側にのみ存在するイベントを返す" do
      google = [event(source: "google", title: "定例MTG", start: "2026-06-20T10:00:00+09:00")]
      outlook = [
        event(source: "outlook", title: "定例MTG", start: "2026-06-20T10:00:00+09:00"),
        event(source: "outlook", title: "顧客訪問", start: "2026-06-21T14:00:00+09:00")
      ]

      result = described_class.outlook_only(google_events: google, outlook_events: outlook)
      expect(result.map(&:title)).to eq(["顧客訪問"])
    end

    it "Google が空なら Outlook の全イベントを返す" do
      outlook = [
        event(source: "outlook", title: "A", start: "2026-06-20T10:00:00+09:00"),
        event(source: "outlook", title: "B", start: "2026-06-21T10:00:00+09:00")
      ]

      result = described_class.outlook_only(google_events: [], outlook_events: outlook)
      expect(result.size).to eq(2)
    end
  end
end
