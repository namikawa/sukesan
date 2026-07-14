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

    def captured_params(request_meet: false, **)
      params = nil
      token = double
      allow(token).to receive(:post) do |*_args, **kwargs|
        params = kwargs[:params]
        double(body: "{}")
      end
      described_class.new(token).create_event(event, request_meet: request_meet, **)
      params
    end

    it "既定では sendUpdates=none（招待メールを送らない）を指定する" do
      expect(captured_params(request_meet: false)).to include(sendUpdates: "none")
      expect(captured_params(request_meet: false)).not_to include(:conferenceDataVersion)
    end

    it "request_meet 時は conferenceDataVersion を追加する" do
      expect(captured_params(request_meet: true)).to include(sendUpdates: "none", conferenceDataVersion: 1)
    end

    it "send_updates: all を指定すると sendUpdates=all になる" do
      expect(captured_params(send_updates: "all")).to include(sendUpdates: "all")
    end

    it "許可値（none/all）以外の send_updates は none に落とす（fail-closed）" do
      expect(captured_params(send_updates: "externalOnly")).to include(sendUpdates: "none")
      expect(captured_params(send_updates: "evil<script>")).to include(sendUpdates: "none")
      expect(captured_params(send_updates: nil)).to include(sendUpdates: "none")
    end
  end

  describe "#create_event の visibility（非公開オプション）" do
    let(:event) { Event.new(source: "google", title: "x", starts_at: t, ends_at: t + 1800, all_day: false) }

    def captured_body(**)
      body = nil
      token = double
      allow(token).to receive(:post) do |*_args, **kwargs|
        body = JSON.parse(kwargs[:body])
        double(body: "{}")
      end
      described_class.new(token).create_event(event, **)
      body
    end

    it "既定では visibility フィールド自体を送らない（Google の既定に委ねる）" do
      expect(captured_body).not_to have_key("visibility")
    end

    it "private_event: true のときだけ visibility=private を送る" do
      expect(captured_body(private_event: true)).to include("visibility" => "private")
    end
  end

  # response.status を持つ OAuth2::Error を作るヘルパ（initialize はレスポンス解析を要するため回避）。
  def oauth2_error(status)
    error = OAuth2::Error.allocate
    allow(error).to receive(:response).and_return(double(status: status))
    error
  end

  describe "#delete_event" do
    it "削除に成功したら true を返す（sendUpdates=none 指定）" do
      token = double
      allow(token).to receive(:delete).and_return(double(body: ""))

      expect(described_class.new(token).delete_event("ev1")).to be(true)
      expect(token).to have_received(:delete)
        .with(%r{/calendars/primary/events/ev1\z}, params: { sendUpdates: "none" })
    end

    it "既に存在しない（404/410）場合も削除済みとして true（冪等）" do
      [404, 410].each do |status|
        token = double
        allow(token).to receive(:delete).and_raise(oauth2_error(status))
        expect(described_class.new(token).delete_event("ev1")).to be(true)
      end
    end

    it "その他のエラー（500 等）はそのまま送出する" do
      token = double
      allow(token).to receive(:delete).and_raise(oauth2_error(500))
      expect { described_class.new(token).delete_event("ev1") }.to raise_error(OAuth2::Error)
    end
  end

  describe "#patch_event" do
    def captured_patch(**)
      captured = nil
      token = double
      allow(token).to receive(:patch) do |*args, **opts|
        captured = { url: args.first, params: opts[:params], body: JSON.parse(opts[:body]) }
        double(body: '{"hangoutLink":"https://meet.google.com/abc"}')
      end
      response = described_class.new(token).patch_event("ev1", **)
      [captured, response]
    end

    it "指定した項目だけを送る（件名・説明）" do
      captured, = captured_patch(summary: "打合せ - 山田 (from 調整ツール)", description: "依頼者: 山田")
      expect(captured[:url]).to match(%r{/calendars/primary/events/ev1\z})
      expect(captured[:params]).to eq(sendUpdates: "none")
      expect(captured[:body]).to eq(
        "summary" => "打合せ - 山田 (from 調整ツール)", "description" => "依頼者: 山田"
      )
    end

    it "参加者と Meet 発行を指定でき、レスポンスを返す" do
      captured, response = captured_patch(summary: "x", attendees: ["a@example.com"], request_meet: true)
      expect(captured[:params]).to include(conferenceDataVersion: 1)
      expect(captured[:body]["attendees"]).to eq([{ "email" => "a@example.com" }])
      expect(captured[:body]["conferenceData"]).to have_key("createRequest")
      expect(response["hangoutLink"]).to eq("https://meet.google.com/abc")
    end

    it "send_updates: all を指定すると sendUpdates=all、許可値以外は none に落とす" do
      captured, = captured_patch(summary: "x", send_updates: "all")
      expect(captured[:params]).to include(sendUpdates: "all")

      captured, = captured_patch(summary: "x", send_updates: "externalOnly")
      expect(captured[:params]).to include(sendUpdates: "none")
    end
  end
end
