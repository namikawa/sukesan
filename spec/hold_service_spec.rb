# frozen_string_literal: true

RSpec.describe HoldService do
  let(:lock) { double("lock") }
  let(:availability) { double("availability") }
  let(:calendar_client) { double("calendar_client") }
  let(:now) { Time.iso8601("2026-06-22T09:00:00+09:00") }
  let(:slots) do
    [[Time.iso8601("2026-06-23T10:00:00+09:00"), Time.iso8601("2026-06-23T10:30:00+09:00")],
     [Time.iso8601("2026-06-24T14:00:00+09:00"), Time.iso8601("2026-06-24T14:30:00+09:00")]]
  end

  subject(:service) do
    described_class.new(lock: lock, availability: availability, calendar_client: calendar_client,
                        event_id_key: "test-event-id-key")
  end

  before do
    allow(lock).to receive(:synchronize).and_yield
    allow(availability).to receive(:slot_available?).and_return(true)
  end

  def hold
    service.hold(token: "tok", requester: "山田", title: "打合せ", slots: slots,
                 holder_key: "holder-secret", now: now)
  end

  describe "#hold" do
    it "チケット遷移後に prefix 付きイベントをスロットごとの決定的 ID で作成する" do
      created = []
      allow(TicketStore).to receive(:hold!).and_return(true)
      allow(calendar_client).to receive(:create_event) do |event, id:|
        created << [event, id]
        {}
      end

      expect(hold.status).to eq(:ok)
      expect(TicketStore).to have_received(:hold!).with(
        "tok", now: now, attrs: hash_including("requester" => "山田", "holder_key" => "holder-secret")
      )
      expect(created.map { |event, _| event.title }).to all(start_with("[仮ブロック] 打合せ - 山田"))
      expect(created.map { |event, _| event.description }).to all(include("仮押さえ"))
      ids = created.map { |_, id| id }
      expect(ids).to all(match(/\Asukesan[0-9a-f]{40}\z/))
      expect(ids.uniq.size).to eq(2) # スロットごとに異なる ID
    end

    it "いずれかの空きが埋まっていれば :slot_taken（チケットに触れない）" do
      allow(availability).to receive(:slot_available?).and_return(true, false)
      allow(TicketStore).to receive(:hold!)

      expect(hold.status).to eq(:slot_taken)
      expect(TicketStore).not_to have_received(:hold!)
    end

    it "チケットが使用可能でなければ :ticket_used（イベントは作らない）" do
      allow(TicketStore).to receive(:hold!).and_return(false)
      allow(calendar_client).to receive(:create_event)

      expect(hold.status).to eq(:ticket_used)
      expect(calendar_client).not_to have_received(:create_event)
    end

    it "作成途中で失敗したら作成済みイベントを削除し、チケットを有効へ戻す（:api_failure）" do
      allow(TicketStore).to receive(:hold!).and_return(true)
      allow(TicketStore).to receive(:reactivate!)
      calls = 0
      allow(calendar_client).to receive(:create_event) do
        calls += 1
        raise StandardError if calls == 2

        {}
      end
      deleted = []
      allow(calendar_client).to receive(:delete_event) { |id| deleted << id }

      result = nil
      expect { result = hold }.to output(/\[HoldService\] 仮押さえの作成失敗/).to_stderr
      expect(result.status).to eq(:api_failure)
      expect(deleted.size).to eq(1) # 1 件目だけ作成済みだったので 1 件だけ削除
      expect(TicketStore).to have_received(:reactivate!).with("tok")
    end

    it "409（既存）は作成済みとして成功扱いにする（再試行の冪等性）" do
      allow(TicketStore).to receive(:hold!).and_return(true)
      allow(calendar_client).to receive(:create_event).and_raise(GoogleCalendarClient::Conflict)

      expect(hold.status).to eq(:ok)
    end
  end

  describe "#confirm" do
    let(:holds) do
      [{ "event_id" => "ev1", "slot_start" => "2026-06-23T10:00:00+09:00",
         "slot_end" => "2026-06-23T10:30:00+09:00" },
       { "event_id" => "ev2", "slot_start" => "2026-06-24T14:00:00+09:00",
         "slot_end" => "2026-06-24T14:30:00+09:00" }]
    end
    let(:ticket) { { "requester" => "山田", "title" => "打合せ" } }

    before do
      allow(TicketStore).to receive(:confirm_hold!).and_return(holds)
      allow(TicketStore).to receive(:find).and_return(ticket)
    end

    def confirm(**)
      service.confirm(token: "tok", slot_start: "2026-06-23T10:00:00+09:00", now: now, **)
    end

    it "決定イベントを prefix 無しの件名へ更新し、他の候補を削除する" do
      allow(calendar_client).to receive(:patch_event).and_return({})
      deleted = []
      allow(calendar_client).to receive(:delete_event) { |id| deleted << id }

      result = confirm
      expect(result.status).to eq(:ok)
      expect(result.failed_deletes).to eq(0)
      expect(calendar_client).to have_received(:patch_event)
        .with("ev1", hash_including(summary: "打合せ - 山田 (from 調整ツール)"))
      expect(deleted).to eq(["ev2"])
    end

    it "request_meet 時は更新レスポンスから Meet リンクを取り出す" do
      allow(calendar_client).to receive(:patch_event)
        .and_return({ "hangoutLink" => "https://meet.google.com/abc" })
      allow(calendar_client).to receive(:delete_event)

      expect(confirm(request_meet: true).meet_link).to eq("https://meet.google.com/abc")
    end

    it "既定は send_updates=none、send_invites 時のみ all で更新する（招待メールのオプトイン）" do
      allow(calendar_client).to receive(:patch_event).and_return({})
      allow(calendar_client).to receive(:delete_event)

      confirm
      expect(calendar_client).to have_received(:patch_event)
        .with("ev1", hash_including(send_updates: "none"))

      confirm(send_invites: true)
      expect(calendar_client).to have_received(:patch_event)
        .with("ev1", hash_including(send_updates: "all"))
    end

    it "決定できない状態（期限切れ・二重決定など）は :not_held" do
      allow(TicketStore).to receive(:confirm_hold!).and_return(nil)
      expect(confirm.status).to eq(:not_held)
    end

    it "件名更新に失敗しても決定は成立し、patch_failed を立てる" do
      allow(calendar_client).to receive(:patch_event).and_raise(StandardError)
      allow(calendar_client).to receive(:delete_event)

      result = nil
      expect { result = confirm }.to output(/決定イベントの更新失敗/).to_stderr
      expect(result.status).to eq(:ok)
      expect(result.patch_failed).to be(true)
    end

    it "他候補の削除失敗は failed_deletes に数える" do
      allow(calendar_client).to receive(:patch_event).and_return({})
      allow(calendar_client).to receive(:delete_event).and_raise(StandardError)

      result = nil
      expect { result = confirm }.to output(/仮押さえイベントの削除失敗/).to_stderr
      expect(result.failed_deletes).to eq(1)
    end
  end

  describe "#remove / #cancel" do
    it "remove は取り除いたエントリのイベントを削除する" do
      removed = { "event_id" => "ev1", "slot_start" => "2026-06-23T10:00:00+09:00" }
      allow(TicketStore).to receive(:remove_hold!).and_return(removed)
      deleted = []
      allow(calendar_client).to receive(:delete_event) { |id| deleted << id }

      result = service.remove(token: "tok", slot_start: "2026-06-23T10:00:00+09:00", now: now)
      expect(result.status).to eq(:ok)
      expect(deleted).to eq(["ev1"])
    end

    it "remove は held でない・スロット不一致なら :not_held" do
      allow(TicketStore).to receive(:remove_hold!).and_return(nil)
      result = service.remove(token: "tok", slot_start: "2026-06-23T10:00:00+09:00", now: now)
      expect(result.status).to eq(:not_held)
    end

    it "cancel はすべての仮押さえイベントを削除する" do
      holds = [{ "event_id" => "ev1" }, { "event_id" => "ev2" }]
      allow(TicketStore).to receive(:cancel_hold!).and_return(holds)
      deleted = []
      allow(calendar_client).to receive(:delete_event) { |id| deleted << id }

      result = service.cancel(token: "tok", now: now)
      expect(result.status).to eq(:ok)
      expect(deleted).to eq(%w[ev1 ev2])
    end
  end
end
