# frozen_string_literal: true

RSpec.describe OutlookCalendarClient do
  def item(subject)
    {
      "id" => subject, "subject" => subject,
      "start" => { "dateTime" => "2026-06-22T09:00:00.000" },
      "end" => { "dateTime" => "2026-06-22T09:30:00.000" },
      "isAllDay" => false
    }
  end

  let(:t) { Time.iso8601("2026-06-22T00:00:00+09:00") }

  it "@odata.nextLink を辿って全ページのイベントを返す" do
    page1 = double(body: {
      "value" => [item("a")],
      "@odata.nextLink" => "https://graph.microsoft.com/v1.0/me/calendarView?$skip=250"
    }.to_json)
    page2 = double(body: { "value" => [item("b")] }.to_json)
    token = double
    allow(token).to receive(:get).and_return(page1, page2)

    events = described_class.new(token).list_events(time_min: t, time_max: t)

    expect(events.map(&:title)).to eq(%w[a b])
    expect(token).to have_received(:get).twice
  end

  it "本文（body.content）を description として取り込む" do
    with_body = item("a").merge("body" => { "contentType" => "text", "content" => "議題: 予算確認" })
    token = double
    allow(token).to receive(:get).and_return(double(body: { "value" => [with_body] }.to_json))

    events = described_class.new(token).list_events(time_min: t, time_max: t)
    expect(events.first.description).to eq("議題: 予算確認")
  end

  it "本文が空白のみなら description は nil" do
    blank_body = item("a").merge("body" => { "content" => "   " })
    token = double
    allow(token).to receive(:get).and_return(double(body: { "value" => [blank_body] }.to_json))

    events = described_class.new(token).list_events(time_min: t, time_max: t)
    expect(events.first.description).to be_nil
  end

  it "想定外ホストの @odata.nextLink は辿らずエラーにする" do
    bad = double(body: {
      "value" => [item("a")],
      "@odata.nextLink" => "https://evil.example.com/v1.0/me/calendarView?$skip=250"
    }.to_json)
    token = double
    allow(token).to receive(:get).and_return(bad)

    expect { described_class.new(token).list_events(time_min: t, time_max: t) }
      .to raise_error(/@odata.nextLink/)
  end

  it "nextLink が無ければ 1 ページで終了する" do
    token = double
    allow(token).to receive(:get).and_return(double(body: { "value" => [item("a")] }.to_json))

    events = described_class.new(token).list_events(time_min: t, time_max: t)

    expect(events.map(&:title)).to eq(%w[a])
    expect(token).to have_received(:get).once
  end
end
