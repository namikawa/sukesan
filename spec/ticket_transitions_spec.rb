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
end
