# frozen_string_literal: true

RSpec.describe GoogleCalendarClient do
  # build_event が参照する最小限のフィールドを持つ items 要素。
  def item(title)
    {
      "id" => title, "summary" => title,
      "start" => { "dateTime" => "2026-06-22T09:00:00Z" },
      "end" => { "dateTime" => "2026-06-22T09:30:00Z" }
    }
  end

  let(:t) { Time.iso8601("2026-06-22T00:00:00+09:00") }

  it "nextPageToken を辿って全ページのイベントを返す" do
    page1 = double(body: { "items" => [item("a"), item("b")], "nextPageToken" => "TOKEN2" }.to_json)
    page2 = double(body: { "items" => [item("c")] }.to_json)
    token = double
    allow(token).to receive(:get).and_return(page1, page2)

    events = described_class.new(token).list_events(time_min: t, time_max: t)

    expect(events.map(&:title)).to eq(%w[a b c])
    expect(token).to have_received(:get).twice
  end

  it "nextPageToken が無ければ 1 ページで終了する" do
    token = double
    allow(token).to receive(:get).and_return(double(body: { "items" => [item("a")] }.to_json))

    events = described_class.new(token).list_events(time_min: t, time_max: t)

    expect(events.map(&:title)).to eq(%w[a])
    expect(token).to have_received(:get).once
  end

  describe "#create_event のクエリパラメータ" do
    let(:event) { Event.new(source: "google", title: "x", starts_at: t, ends_at: t + 1800, all_day: false) }

    def captured_params(request_meet:)
      params = nil
      token = double
      allow(token).to receive(:post) do |*_args, **kwargs|
        params = kwargs[:params]
        double(body: "{}")
      end
      described_class.new(token).create_event(event, request_meet: request_meet)
      params
    end

    it "通知抑止のため sendUpdates=none を常に指定する" do
      expect(captured_params(request_meet: false)).to include(sendUpdates: "none")
      expect(captured_params(request_meet: false)).not_to include(:conferenceDataVersion)
    end

    it "request_meet 時は conferenceDataVersion を追加する" do
      expect(captured_params(request_meet: true)).to include(sendUpdates: "none", conferenceDataVersion: 1)
    end
  end
end
