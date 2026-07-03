# frozen_string_literal: true

RSpec.describe Event do
  def event(**attrs)
    described_class.new(
      source: "outlook",
      title: "定例MTG",
      starts_at: Time.parse("2026-06-20T10:00:00+09:00"),
      ends_at: Time.parse("2026-06-20T11:00:00+09:00"),
      all_day: false,
      **attrs
    )
  end

  describe "#match_key" do
    it "件名の前後空白と大文字小文字を無視する" do
      a = event(title: " Review ")
      b = event(title: "review")
      expect(a.match_key).to eq(b.match_key)
    end

    it "先頭の「Fw:」（Fwd: 含む）を無視して一致する" do
      fw = event(title: "Fw: 定例MTG")
      plain = event(title: "定例MTG")
      expect(fw.match_key).to eq(plain.match_key)
    end

    it "開始・終了が同じなら（タイムゾーン表記が違っても）一致する" do
      jst = event(starts_at: Time.parse("2026-06-20T10:00:00+09:00"))
      utc = event(starts_at: Time.parse("2026-06-20T01:00:00+00:00"))
      expect(jst.match_key).to eq(utc.match_key)
    end

    it "開始時刻が異なれば一致しない" do
      a = event(starts_at: Time.parse("2026-06-20T10:00:00+09:00"))
      b = event(starts_at: Time.parse("2026-06-20T12:00:00+09:00"))
      expect(a.match_key).not_to eq(b.match_key)
    end

    it "終日予定は日付単位で判定する" do
      a = event(all_day: true, starts_at: Time.parse("2026-06-20T00:00:00+00:00"))
      b = event(all_day: true, starts_at: Time.parse("2026-06-20T05:00:00+00:00"))
      expect(a.match_key).to eq(b.match_key)
    end
  end
end
