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

  describe ".expired?（発行時に選んだ有効期限 ttl_hours で判定）" do
    def ticket_with_ttl(ttl_hours)
      t = { "created_at" => now.iso8601 }
      t["ttl_hours"] = ttl_hours unless ttl_hours == :none
      t
    end

    it "許可値（24/72/168）ごとに期限境界の前後で active / expired が切り替わる" do
      [24, 72, 168].each do |hours|
        t = ticket_with_ttl(hours)
        boundary = now + (hours * 3600)
        expect(described_class.status(t, now: boundary)).to eq("active")
        expect(described_class.status(t, now: boundary + 1)).to eq("expired")
      end
    end

    it "ttl_hours を持たない既存形式のチケットは 24 時間扱い（後方互換）" do
      t = ticket_with_ttl(:none)
      boundary = now + (24 * 3600)
      expect(described_class.status(t, now: boundary)).to eq("active")
      expect(described_class.status(t, now: boundary + 1)).to eq("expired")
    end

    it "許可外の ttl_hours（48・文字列・0）は 24 時間に落とす（fail-closed）" do
      [48, "abc", 0, 10_000].each do |bad|
        t = ticket_with_ttl(bad)
        expect(described_class.status(t, now: now + (24 * 3600) + 1)).to eq("expired")
      end
    end

    it "held の期限は held_at + 7 日のまま（ttl_hours の影響を受けない）" do
      t = { "status" => "held", "created_at" => now.iso8601, "held_at" => now.iso8601, "ttl_hours" => 24 }
      boundary = now + (7 * 86_400)
      expect(described_class.status(t, now: boundary)).to eq("held")
      expect(described_class.status(t, now: boundary + 1)).to eq("expired")
    end
  end

  describe ".normalize_ttl_hours（発行時の入力の正規化）" do
    it "許可値（24/72/168）は整数で返す（文字列の params も受ける）" do
      expect(described_class.normalize_ttl_hours("24")).to eq(24)
      expect(described_class.normalize_ttl_hours("72")).to eq(72)
      expect(described_class.normalize_ttl_hours(168)).to eq(168)
    end

    it "許可外・欠落は既定の 24 に落とす" do
      ["48", "abc", "", nil, "-72", "1680"].each do |bad|
        expect(described_class.normalize_ttl_hours(bad)).to eq(described_class::DEFAULT_TTL_HOURS)
      end
    end
  end
end
