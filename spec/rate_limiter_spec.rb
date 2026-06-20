# frozen_string_literal: true

RSpec.describe RateLimiter do
  let(:base) { Time.parse("2026-06-22T09:00:00+09:00") }

  it "上限までは許可し、超過すると拒否する" do
    limiter = described_class.new(max: 2, window_seconds: 60)

    expect(limiter.allow?("1.1.1.1", now: base)).to be(true)
    expect(limiter.allow?("1.1.1.1", now: base)).to be(true)
    expect(limiter.allow?("1.1.1.1", now: base)).to be(false)
  end

  it "ウィンドウを過ぎた古い記録は数えない" do
    limiter = described_class.new(max: 1, window_seconds: 60)

    expect(limiter.allow?("1.1.1.1", now: base)).to be(true)
    expect(limiter.allow?("1.1.1.1", now: base + 30)).to be(false)
    expect(limiter.allow?("1.1.1.1", now: base + 61)).to be(true)
  end

  it "キー（IP）ごとに独立して数える" do
    limiter = described_class.new(max: 1, window_seconds: 60)

    expect(limiter.allow?("1.1.1.1", now: base)).to be(true)
    expect(limiter.allow?("2.2.2.2", now: base)).to be(true)
    expect(limiter.allow?("1.1.1.1", now: base)).to be(false)
  end
end
