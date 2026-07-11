# frozen_string_literal: true

require "ticket_status"

RSpec.describe TicketStatus do
  let(:now) { Time.iso8601("2026-06-20T10:00:00+09:00") }

  def ticket(status: nil, created_at: nil, held_at: nil)
    { "status" => status, "created_at" => (created_at || now).iso8601, "held_at" => held_at&.iso8601 }
      .compact
  end

  describe ".status（未知の status は fail-closed）" do
    it "既知の終端状態はそのまま返す" do
      %w[used revoked cancelled].each do |s|
        expect(described_class.status(ticket(status: s), now: now)).to eq(s)
      end
    end

    it "status 未設定（nil）は active" do
      expect(described_class.status(ticket, now: now)).to eq("active")
    end

    it "未知の status 値（期限内でも）は invalid を返す" do
      expect(described_class.status(ticket(status: "broken"), now: now)).to eq("invalid")
    end

    it "未知の status では active? も held? も false になる" do
      t = ticket(status: "broken")
      expect(described_class.active?(t, now: now)).to be(false)
      expect(described_class.held?(t, now: now)).to be(false)
    end
  end
end
