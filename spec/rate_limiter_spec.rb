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

  # メモリの単調増加（再訪しない IP のキーが溜まり続ける）を防ぐ sweep の検証。
  def hits(limiter)
    limiter.instance_variable_get(:@hits)
  end

  it "期限切れになったキーは sweep でハッシュごと削除する" do
    limiter = described_class.new(max: 1, window_seconds: 60)

    limiter.allow?("1.1.1.1", now: base)
    limiter.allow?("2.2.2.2", now: base)
    expect(hits(limiter).size).to eq(2)

    # window 経過後に別キーへアクセスすると sweep が走り、期限切れキーが消える。
    limiter.allow?("3.3.3.3", now: base + 61)
    expect(hits(limiter).keys).to eq(["3.3.3.3"])
  end

  it "exceeded? は存在しないキーの空エントリを作らない" do
    limiter = described_class.new(max: 1, window_seconds: 60)

    expect(limiter.exceeded?("9.9.9.9", now: base)).to be(false)
    expect(hits(limiter)).to be_empty
  end
end
