# frozen_string_literal: true

require "ticket_transitions"

RSpec.describe TicketTransitions do
  let(:now) { Time.iso8601("2026-06-20T10:00:00+09:00") }

  describe ".reactivate（遷移元を used / held に限定）" do
    it "used から active へ戻し、保存した入力値を消す" do
      ticket = { "token" => "t", "status" => "used", "used_at" => now.iso8601,
                 "requester" => "山田", "title" => "打合せ" }
      updated, value = described_class.reactivate(ticket)

      expect(value).to be(true)
      expect(updated["status"]).to eq("active")
      expect(updated).not_to have_key("requester")
      expect(updated).not_to have_key("used_at")
    end

    it "held から active へ戻し、仮押さえ関連キーを消す（作成途中失敗のロールバック）" do
      ticket = { "token" => "t", "status" => "held", "held_at" => now.iso8601,
                 "holder_key" => "k", "holds" => [{ "event_id" => "ev1" }] }
      updated, = described_class.reactivate(ticket)

      expect(updated["status"]).to eq("active")
      expect(updated).not_to have_key("holds")
      expect(updated).not_to have_key("holder_key")
    end

    it "終端状態（revoked / cancelled）からは戻せない（nil）" do
      %w[revoked cancelled].each do |s|
        expect(described_class.reactivate({ "status" => s })).to be_nil
      end
    end

    it "不正・未設定の status からは戻せない（nil）" do
      expect(described_class.reactivate({ "status" => "broken" })).to be_nil
      expect(described_class.reactivate({})).to be_nil
    end
  end

  describe ".cancel_booking（used → cancelled）" do
    let(:booked) do
      { "token" => "t", "status" => "used", "used_at" => now.iso8601, "created_at" => now.iso8601,
        "requester" => "山田", "title" => "打合せ", "slot_start" => "2026-06-22T10:00:00+09:00",
        "slot_end" => "2026-06-22T10:30:00+09:00", "event_id" => "sukesanev1" }
    end

    it "event_id を保存した used を cancelled にし、遷移前のチケットを返す（削除対象の event_id 取得用）" do
      updated, previous = described_class.cancel_booking(booked, now: now)

      expect(updated["status"]).to eq("cancelled")
      expect(updated["cancelled_at"]).to eq(now.iso8601)
      expect(previous["event_id"]).to eq("sukesanev1")
      # 登録内容は残す（何を取り消したのかを管理画面・API・通知で辿れるようにする）。
      expect(updated["requester"]).to eq("山田")
      expect(updated["slot_start"]).to eq("2026-06-22T10:00:00+09:00")
    end

    it "event_id 未保存・空の used は取り消せない（削除対象の予定を特定できない既存チケット）" do
      expect(described_class.cancel_booking(booked.except("event_id"), now: now)).to be_nil
      expect(described_class.cancel_booking(booked.merge("event_id" => ""), now: now)).to be_nil
    end

    it "used 以外（active / held）からは取り消せない（nil）" do
      active = { "created_at" => now.iso8601, "event_id" => "sukesanev1" }
      held = { "created_at" => now.iso8601, "status" => "held", "held_at" => now.iso8601,
               "event_id" => "sukesanev1" }

      expect(described_class.cancel_booking(active, now: now)).to be_nil
      expect(described_class.cancel_booking(held, now: now)).to be_nil
    end

    it "終端状態（cancelled / revoked）・破損した status からは取り消せない（二重取消も不可）" do
      %w[cancelled revoked broken].each do |s|
        expect(described_class.cancel_booking(booked.merge("status" => s), now: now)).to be_nil
      end
    end
  end

  describe ".confirm_hold" do
    let(:held) do
      { "token" => "t", "status" => "held", "held_at" => now.iso8601, "created_at" => now.iso8601,
        "holder_key" => "k",
        "holds" => [{ "event_id" => "ev1", "slot_start" => "2026-06-22T10:00:00+09:00",
                      "slot_end" => "2026-06-22T10:30:00+09:00" },
                    { "event_id" => "ev2", "slot_start" => "2026-06-23T14:00:00+09:00",
                      "slot_end" => "2026-06-23T14:30:00+09:00" }] }
    end

    it "決定したイベントの ID を event_id として保存する（取消の対象にするため）" do
      updated, holds = described_class.confirm_hold(held, slot_start: "2026-06-23T14:00:00+09:00",
                                                          attrs: {}, now: now)

      expect(updated["status"]).to eq("used")
      expect(updated["event_id"]).to eq("ev2")
      expect(updated["slot_start"]).to eq("2026-06-23T14:00:00+09:00")
      expect(holds.map { |h| h["event_id"] }).to eq(%w[ev1 ev2])
    end
  end
end
