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
    # 登録失敗後の存在確認は既定で「作られていない」（404 相当）。
    allow(calendar_client).to receive(:get_event).and_return(nil)
    allow(TicketStore).to receive(:use!).and_return(true)
    allow(TicketStore).to receive(:reactivate!)
  end

  def call
    service.call(token: "tok", event: event, ticket_attrs: ticket_attrs)
  end

  it "空きあり・チケット有効なら登録して :ok を返す（決定的 event id・既定 sendUpdates=none・非公開なし）" do
    expect(calendar_client).to receive(:create_event)
      .with(event, attendees: [], request_meet: false, send_updates: "none", private_event: false,
                   id: a_string_matching(/\Asukesan[0-9a-f]{40}\z/))
      .and_return({})
    # 登録したイベント ID はチケットにも保存する（取消時の削除対象をチケット保存値だけに限るため）。
    expected_id = described_class.event_id("test-event-id-key", "tok")
    expect(TicketStore).to receive(:use!)
      .with("tok", attrs: ticket_attrs.merge("event_id" => expected_id)).and_return(true)

    expect(call.status).to eq(:ok)
  end

  it "event_id を渡すとその ID で登録し、チケットにも同じ ID を保存する（冪等キー由来の ID）" do
    expect(calendar_client).to receive(:create_event)
      .with(event, attendees: [], request_meet: false, send_updates: "none", private_event: false,
                   id: "sukesan-external-id")
      .and_return({})
    expect(TicketStore).to receive(:use!)
      .with("tok", attrs: ticket_attrs.merge("event_id" => "sukesan-external-id")).and_return(true)

    result = service.call(token: "tok", event: event, ticket_attrs: ticket_attrs, event_id: "sukesan-external-id")
    expect(result.status).to eq(:ok)
  end

  it ".event_id は入力ごとに決定的で、material が違えば別の ID になる" do
    expect(described_class.event_id("k", "tok")).to eq(described_class.event_id("k", "tok"))
    expect(described_class.event_id("k", "tok")).not_to eq(described_class.event_id("k", "idem:tok"))
    expect(described_class.event_id("k", "tok")).to match(/\Asukesan[0-9a-f]{40}\z/)
  end

  it "send_invites 時は send_updates=all で登録する（招待メールのオプトイン）" do
    expect(calendar_client).to receive(:create_event)
      .with(event, attendees: [], request_meet: false, send_updates: "all", private_event: false, id: anything)
      .and_return({})

    result = service.call(token: "tok", event: event, ticket_attrs: ticket_attrs, send_invites: true)
    expect(result.status).to eq(:ok)
  end

  it "private_event 時は非公開で登録する（visibility のオプトイン）" do
    expect(calendar_client).to receive(:create_event)
      .with(event, attendees: [], request_meet: false, send_updates: "none", private_event: true, id: anything)
      .and_return({})

    result = service.call(token: "tok", event: event, ticket_attrs: ticket_attrs, private_event: true)
    expect(result.status).to eq(:ok)
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

  it "event_id を指定した登録で Google が 409 を返したら :idempotency_conflict（token を有効へ戻す）" do
    # 冪等キー由来の ID は、取り消して削除した予定の ID とも衝突する（削除した ID は再利用できない）。
    # 予定が無いのに成功を返さず、キーの衝突として呼び出し側へ返す。
    allow(calendar_client).to receive(:create_event).and_raise(GoogleCalendarClient::Conflict)
    expect(TicketStore).to receive(:reactivate!).with("tok")

    result = service.call(token: "tok", event: event, ticket_attrs: ticket_attrs, event_id: "sukesan-external-id")
    expect(result.status).to eq(:idempotency_conflict)
  end

  describe "応答を受け取れなかったときの回収" do
    # 回収の条件は「予定が生きている」ことに加えて「時間帯が今回の登録内容と一致する」こと。
    # オフセット表記は event（+09:00）と違えてあり、Time に変換して比較していることも確認する。
    let(:created_response) do
      { "id" => "sukesanev1", "status" => "confirmed",
        "start" => { "dateTime" => "2026-06-22T01:00:00Z" },
        "end" => { "dateTime" => "2026-06-22T01:30:00Z" } }
    end

    before { allow(calendar_client).to receive(:create_event).and_raise(StandardError) }

    it "Google 側に予定があれば作成成功として :ok（token は使用済みのまま）" do
      allow(calendar_client).to receive(:get_event).and_return(created_response)
      expect(TicketStore).not_to receive(:reactivate!)

      expect(call.status).to eq(:ok)
    end

    it "回収した応答から Meet リンクを取り出す" do
      allow(calendar_client).to receive(:get_event)
        .and_return(created_response.merge("hangoutLink" => "https://meet.google.com/abc-defg-hij"))

      result = service.call(token: "tok", event: event, ticket_attrs: ticket_attrs, request_meet: true)
      expect(result.meet_link).to eq("https://meet.google.com/abc-defg-hij")
    end

    it "予定が無ければ（404）従来どおり :api_failure" do
      allow(calendar_client).to receive(:get_event).and_return(nil)
      expect(TicketStore).to receive(:reactivate!).with("tok")

      result = nil
      expect { result = call }.to output(/\[BookingService\] 登録失敗/).to_stderr
      expect(result.status).to eq(:api_failure)
    end

    # 冪等キー由来の ID は、30 日より前の同じキーの予約や並行実行が作った予定とも一致し得る。
    it "時間帯が違う予定は今回の登録とみなさない（別内容での偽成功を防ぐ）" do
      allow(calendar_client).to receive(:get_event)
        .and_return(created_response.merge("start" => { "dateTime" => "2026-06-22T14:00:00+09:00" },
                                           "end" => { "dateTime" => "2026-06-22T14:30:00+09:00" }))
      expect(TicketStore).to receive(:reactivate!).with("tok")

      result = nil
      expect { result = service.call(token: "tok", event: event, ticket_attrs: ticket_attrs, event_id: "ev-x") }
        .to output(/\[BookingService\] 登録失敗/).to_stderr
      expect(result.status).to eq(:api_failure)
    end

    it "終日予定（dateTime を持たない）は時間帯を照合できないため回収しない" do
      allow(calendar_client).to receive(:get_event)
        .and_return("id" => "sukesanev1", "status" => "confirmed",
                    "start" => { "date" => "2026-06-22" }, "end" => { "date" => "2026-06-23" })
      expect(TicketStore).to receive(:reactivate!).with("tok")

      expect { expect(call.status).to eq(:api_failure) }.to output.to_stderr
    end

    it "削除済み（status: cancelled）の予定は作成成功とみなさない" do
      allow(calendar_client).to receive(:get_event).and_return("id" => "sukesanev1", "status" => "cancelled")
      expect(TicketStore).to receive(:reactivate!).with("tok")

      expect { expect(call.status).to eq(:api_failure) }.to output.to_stderr
    end

    it "存在確認自体が失敗したら :api_failure（曖昧なら失敗側へ倒す）" do
      allow(calendar_client).to receive(:get_event).and_raise(StandardError)
      expect(TicketStore).to receive(:reactivate!).with("tok")

      result = nil
      expect { result = call }.to output(/登録結果の確認失敗: StandardError/).to_stderr
      expect(result.status).to eq(:api_failure)
    end

    it "確認に使う ID は登録に使った ID と同じ" do
      expect(calendar_client).to receive(:get_event)
        .with(described_class.event_id("test-event-id-key", "tok")).and_return(nil)

      expect { call }.to output.to_stderr
    end
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

  it "Google 登録が失敗したら token を有効へ戻し :api_failure を返す（例外クラスをログに残す）" do
    allow(calendar_client).to receive(:create_event).and_raise(StandardError)
    expect(TicketStore).to receive(:reactivate!).with("tok")

    result = nil
    expect { result = call }.to output(/\[BookingService\] 登録失敗: StandardError/).to_stderr
    expect(result.status).to eq(:api_failure)
  end

  it "request_meet 時は応答から Meet リンクを取り出して返す" do
    response = { "hangoutLink" => "https://meet.google.com/abc-defg-hij" }
    allow(calendar_client).to receive(:create_event)
      .with(event, attendees: [], request_meet: true, send_updates: "none", private_event: false, id: anything)
      .and_return(response)

    result = service.call(token: "tok", event: event, ticket_attrs: ticket_attrs, request_meet: true)
    expect(result.status).to eq(:ok)
    expect(result.meet_link).to eq("https://meet.google.com/abc-defg-hij")
  end

  it "request_meet でなければ meet_link は nil" do
    allow(calendar_client).to receive(:create_event).and_return({ "hangoutLink" => "x" })
    expect(call.meet_link).to be_nil
  end
end
