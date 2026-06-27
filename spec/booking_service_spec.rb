# frozen_string_literal: true

RSpec.describe BookingService do
  let(:lock) { double("lock") }
  let(:availability) { double("availability") }
  let(:calendar_client) { double("calendar_client") }
  let(:event) do
    Event.new(source: "google", title: "打合せ - 山田 (from 調整ツール)",
              starts_at: Time.iso8601("2026-06-22T10:00:00+09:00"),
              ends_at: Time.iso8601("2026-06-22T10:30:00+09:00"),
              all_day: false, description: "依頼者: 山田")
  end
  let(:ticket_attrs) { { "requester" => "山田", "title" => "打合せ" } }

  subject(:service) do
    described_class.new(lock: lock, availability: availability, calendar_client: calendar_client,
                        event_id_key: "test-event-id-key")
  end

  before do
    # ロックはそのままブロックを実行する（直列化の検証は対象外）。
    allow(lock).to receive(:synchronize).and_yield
    allow(availability).to receive(:slot_available?).and_return(true)
    allow(TicketStore).to receive(:use!).and_return(true)
    allow(TicketStore).to receive(:reactivate!)
  end

  def call
    service.call(token: "tok", event: event, ticket_attrs: ticket_attrs)
  end

  it "空きあり・チケット有効なら登録して :ok を返す（決定的 event id を付ける）" do
    expect(calendar_client).to receive(:create_event)
      .with(event, attendees: [], request_meet: false, id: a_string_matching(/\Asukesan[0-9a-f]{40}\z/))
      .and_return({})
    expect(TicketStore).to receive(:use!).with("tok", attrs: ticket_attrs).and_return(true)

    expect(call.status).to eq(:ok)
  end

  it "同じ token は同じ event id を生成する（再試行の冪等性）" do
    ids = []
    allow(calendar_client).to receive(:create_event) do |*, id:, **|
      ids << id
      {}
    end
    call
    call
    expect(ids.uniq.size).to eq(1)
  end

  it "Google が 409（既存）を返したら重複作成せず :ok（reactivate しない）" do
    allow(calendar_client).to receive(:create_event).and_raise(GoogleCalendarClient::Conflict)
    expect(TicketStore).not_to receive(:reactivate!)

    expect(call.status).to eq(:ok)
  end

  it "ロック内の再確認で枠が埋まっていれば :slot_taken（チケットは消費しない）" do
    allow(availability).to receive(:slot_available?).and_return(false)
    expect(TicketStore).not_to receive(:use!)
    expect(calendar_client).not_to receive(:create_event)

    expect(call.status).to eq(:slot_taken)
  end

  it "チケットが既に使用済みなら :ticket_used（登録しない）" do
    allow(TicketStore).to receive(:use!).and_return(false)
    expect(calendar_client).not_to receive(:create_event)

    expect(call.status).to eq(:ticket_used)
  end

  it "Google 登録が失敗したら token を有効へ戻し :api_failure を返す" do
    allow(calendar_client).to receive(:create_event).and_raise(StandardError)
    expect(TicketStore).to receive(:reactivate!).with("tok")

    expect(call.status).to eq(:api_failure)
  end

  it "request_meet 時は応答から Meet リンクを取り出して返す" do
    response = { "hangoutLink" => "https://meet.google.com/abc-defg-hij" }
    allow(calendar_client).to receive(:create_event)
      .with(event, attendees: [], request_meet: true, id: anything).and_return(response)

    result = service.call(token: "tok", event: event, ticket_attrs: ticket_attrs, request_meet: true)
    expect(result.status).to eq(:ok)
    expect(result.meet_link).to eq("https://meet.google.com/abc-defg-hij")
  end

  it "request_meet でなければ meet_link は nil" do
    allow(calendar_client).to receive(:create_event).and_return({ "hangoutLink" => "x" })
    expect(call.meet_link).to be_nil
  end
end
