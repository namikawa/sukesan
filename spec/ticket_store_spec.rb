# frozen_string_literal: true

require "tmpdir"

RSpec.describe TicketStore do
  around do |example|
    prev = ENV.fetch("TICKETS_DIR", nil)
    Dir.mktmpdir do |dir|
      ENV["TICKETS_DIR"] = dir
      example.run
    ensure
      ENV["TICKETS_DIR"] = prev
    end
  end

  let(:now) { Time.iso8601("2026-06-20T10:00:00+09:00") }

  describe ".create / .find" do
    it "発行したトークンは有効な状態で取得できる" do
      token = described_class.create(now: now)
      ticket = described_class.find(token, now: now)
      expect(ticket["token"]).to eq(token)
      expect(described_class.status(ticket, now: now)).to eq("active")
    end

    it "存在しないトークンは nil" do
      expect(described_class.find("nope", now: now)).to be_nil
    end

    it "保存ファイルの権限は 0600（本人のみ読み書き可）" do
      described_class.create(now: now)
      file = Dir.glob(File.join(ENV.fetch("TICKETS_DIR"), "tickets-*.json")).first
      expect(format("%o", File.stat(file).mode & 0o777)).to eq("600")
    end

    it "保存ファイルは暗号化され、トークンも平文 JSON も露出しない" do
      token = described_class.create(now: now)
      raw = File.read(Dir.glob(File.join(ENV.fetch("TICKETS_DIR"), "tickets-*.json")).first)

      expect(raw).not_to include(token)
      expect { JSON.parse(raw) }.to raise_error(JSON::ParserError)
    end

    it "破損したバケットファイルは空として扱う（fail-closed）" do
      FileUtils.mkdir_p(ENV.fetch("TICKETS_DIR"))
      path = File.join(ENV.fetch("TICKETS_DIR"), "tickets-#{now.strftime('%G-W%V')}.json")
      File.write(path, "corrupted-not-json-not-encrypted")

      expect(described_class.find("anything", now: now)).to be_nil
      expect(described_class.all(now: now)).to eq([])
    end

    it "短い破損データ（base64 は正しいが暗号文が不完全）も空として扱う（fail-closed）" do
      FileUtils.mkdir_p(ENV.fetch("TICKETS_DIR"))
      path = File.join(ENV.fetch("TICKETS_DIR"), "tickets-#{now.strftime('%G-W%V')}.json")
      File.write(path, Base64.strict_encode64("xx"))

      expect(described_class.find("anything", now: now)).to be_nil
      expect(described_class.all(now: now)).to eq([])
    end
  end

  describe ".use!" do
    it "有効なら使用済みにし、入力値を保存する" do
      token = described_class.create(now: now)
      ok = described_class.use!(token, attrs: { "requester" => "山田", "title" => "打合せ" }, now: now)
      ticket = described_class.find(token, now: now)

      expect(ok).to be(true)
      expect(described_class.status(ticket, now: now)).to eq("used")
      expect(ticket["requester"]).to eq("山田")
      expect(ticket["title"]).to eq("打合せ")
      expect(ticket["used_at"]).not_to be_nil
    end

    it "使用済みのトークンは再度使用できない" do
      token = described_class.create(now: now)
      described_class.use!(token, attrs: {}, now: now)
      expect(described_class.use!(token, attrs: {}, now: now)).to be(false)
    end

    it "期限切れのトークンは使用できない" do
      token = described_class.create(now: now)
      later = now + TicketStatus::TTL_SECONDS + 1
      expect(described_class.use!(token, attrs: {}, now: later)).to be(false)
    end
  end

  describe ".reactivate!" do
    it "使用済みから有効へ戻し、保存した入力値を消す" do
      token = described_class.create(now: now)
      described_class.use!(token, attrs: { "requester" => "山田", "title" => "打合せ" }, now: now)
      described_class.reactivate!(token, now: now)
      ticket = described_class.find(token, now: now)

      expect(described_class.status(ticket, now: now)).to eq("active")
      expect(ticket).not_to have_key("requester")
      expect(ticket).not_to have_key("used_at")
    end
  end

  describe ".revoke" do
    it "有効なトークンを無効化し、遷移前のチケットを返す" do
      token = described_class.create(now: now)
      expect(described_class.revoke(token, now: now)).to include("status" => "active")
      expect(described_class.status(described_class.find(token, now: now), now: now)).to eq("revoked")
    end

    it "使用済みのトークンは無効化できない" do
      token = described_class.create(now: now)
      described_class.use!(token, attrs: {}, now: now)
      expect(described_class.revoke(token, now: now)).to be(false)
    end

    it "仮押さえ中のトークンも無効化でき、holds を含む遷移前チケットを返す（kill switch 用）" do
      token = hold_ticket
      previous = described_class.revoke(token, now: now)
      expect(previous["holds"].size).to eq(2)
      expect(described_class.status(described_class.find(token, now: now), now: now)).to eq("revoked")
    end
  end

  # 2 枠の仮押さえ済みチケットを作るヘルパ。
  def hold_ticket(at: now)
    token = described_class.create(now: at)
    described_class.hold!(token, now: at, attrs: {
                            "requester" => "山田", "title" => "打合せ", "holder_key" => "holder-secret",
                            "holds" => [
                              { "event_id" => "ev1", "slot_start" => "2026-06-22T10:00:00+09:00",
                                "slot_end" => "2026-06-22T10:30:00+09:00" },
                              { "event_id" => "ev2", "slot_start" => "2026-06-23T14:00:00+09:00",
                                "slot_end" => "2026-06-23T14:30:00+09:00" }
                            ]
                          })
    token
  end

  describe ".hold! / .held?" do
    it "有効なチケットを仮押さえ状態にし、held_at を記録する" do
      token = hold_ticket
      ticket = described_class.find(token, now: now)

      expect(described_class.status(ticket, now: now)).to eq("held")
      expect(described_class.held?(ticket, now: now)).to be(true)
      expect(described_class.active?(ticket, now: now)).to be(false)
      expect(ticket["held_at"]).to eq(now.iso8601)
      expect(ticket["holds"].map { |h| h["event_id"] }).to eq(%w[ev1 ev2])
    end

    it "使用済みのチケットは仮押さえできない" do
      token = described_class.create(now: now)
      described_class.use!(token, attrs: {}, now: now)
      expect(described_class.hold!(token, attrs: { "holds" => [] }, now: now)).to be(false)
    end

    it "仮押さえ中は通常の予約（use!）ができない" do
      token = hold_ticket
      expect(described_class.use!(token, attrs: {}, now: now)).to be(false)
    end

    it "仮押さえから 7 日を超えると expired になる" do
      token = hold_ticket
      later = now + TicketStatus::HOLD_TTL_SECONDS + 60
      ticket = described_class.find(token, now: later)
      expect(described_class.status(ticket, now: later)).to eq("expired")
      expect(described_class.held?(ticket, now: later)).to be(false)
    end

    it "発行から 24 時間を過ぎても、仮押さえ済みなら held のまま有効" do
      token = hold_ticket
      later = now + TicketStatus::TTL_SECONDS + 3600 # 発行 25 時間後（held_at からは 7 日以内）
      expect(described_class.held?(described_class.find(token, now: later), now: later)).to be(true)
    end
  end

  describe ".confirm_hold!" do
    it "選んだスロットで確定し、確定前の holds を返す" do
      token = hold_ticket
      holds = described_class.confirm_hold!(token, slot_start: "2026-06-22T10:00:00+09:00",
                                                   attrs: { "attendees" => ["a@example.com"] }, now: now)

      expect(holds.map { |h| h["event_id"] }).to eq(%w[ev1 ev2])
      ticket = described_class.find(token, now: now)
      expect(described_class.status(ticket, now: now)).to eq("used")
      expect(ticket["slot_start"]).to eq("2026-06-22T10:00:00+09:00")
      expect(ticket).not_to have_key("holds")
      expect(ticket).not_to have_key("holder_key")
    end

    it "holds に無いスロットでは確定できない" do
      token = hold_ticket
      expect(described_class.confirm_hold!(token, slot_start: "2026-06-24T10:00:00+09:00",
                                                  attrs: {}, now: now)).to be_nil
    end

    it "二重決定はできない（2 回目は nil）" do
      token = hold_ticket
      described_class.confirm_hold!(token, slot_start: "2026-06-22T10:00:00+09:00", attrs: {}, now: now)
      expect(described_class.confirm_hold!(token, slot_start: "2026-06-23T14:00:00+09:00",
                                                  attrs: {}, now: now)).to be_nil
    end

    it "期限切れ（held_at から 7 日超）では確定できない" do
      token = hold_ticket
      later = now + TicketStatus::HOLD_TTL_SECONDS + 60
      expect(described_class.confirm_hold!(token, slot_start: "2026-06-22T10:00:00+09:00",
                                                  attrs: {}, now: later)).to be_nil
    end
  end

  describe ".remove_hold! / .cancel_hold!" do
    it "1 件を取り除き、取り除いたエントリを返す" do
      token = hold_ticket
      removed = described_class.remove_hold!(token, slot_start: "2026-06-22T10:00:00+09:00", now: now)

      expect(removed["event_id"]).to eq("ev1")
      ticket = described_class.find(token, now: now)
      expect(described_class.status(ticket, now: now)).to eq("held")
      expect(ticket["holds"].map { |h| h["event_id"] }).to eq(["ev2"])
    end

    it "最後の 1 件を取り除くと cancelled（終了）になる" do
      token = hold_ticket
      described_class.remove_hold!(token, slot_start: "2026-06-22T10:00:00+09:00", now: now)
      described_class.remove_hold!(token, slot_start: "2026-06-23T14:00:00+09:00", now: now)

      ticket = described_class.find(token, now: now)
      expect(described_class.status(ticket, now: now)).to eq("cancelled")
      expect(ticket).not_to have_key("holds")
    end

    it "holds に無いスロットの削除は nil" do
      token = hold_ticket
      expect(described_class.remove_hold!(token, slot_start: "2026-06-24T10:00:00+09:00", now: now)).to be_nil
    end

    it "cancel_hold! はすべて取りやめて cancelled にし、holds を返す" do
      token = hold_ticket
      holds = described_class.cancel_hold!(token, now: now)

      expect(holds.size).to eq(2)
      expect(described_class.status(described_class.find(token, now: now), now: now)).to eq("cancelled")
    end

    it "cancelled のチケットは confirm_hold! できない" do
      token = hold_ticket
      described_class.cancel_hold!(token, now: now)
      expect(described_class.confirm_hold!(token, slot_start: "2026-06-22T10:00:00+09:00",
                                                  attrs: {}, now: now)).to be_nil
    end
  end

  describe "週またぎの検索（SEARCH_WEEKS）" do
    it "チケット寿命の最悪ケース（発行週から ISO 週 3 バケット目）でも find・遷移できる" do
      created = Time.iso8601("2026-06-21T23:00:00+09:00")      # 日曜（W25 最終日）に発行
      held_at = created + (23 * 3600)                          # 発行 23 時間後（W26 月曜）に仮押さえ
      later = held_at + TicketStatus::HOLD_TTL_SECONDS - 3600  # 期限 1 時間前（W27 月曜）に確定
      token = described_class.create(now: created)
      described_class.hold!(token, now: held_at, attrs: {
                              "holder_key" => "k",
                              "holds" => [{ "event_id" => "ev1", "slot_start" => "2026-06-29T10:00:00+09:00",
                                            "slot_end" => "2026-06-29T10:30:00+09:00" }]
                            })

      expect(described_class.find(token, now: later)).not_to be_nil
      expect(described_class.confirm_hold!(token, slot_start: "2026-06-29T10:00:00+09:00",
                                                  attrs: {}, now: later)).not_to be_nil
    end
  end

  describe ".status" do
    it "TTL を過ぎると expired になる" do
      token = described_class.create(now: now)
      ticket = described_class.find(token, now: now)
      later = now + TicketStatus::TTL_SECONDS + 1
      expect(described_class.status(ticket, now: later)).to eq("expired")
    end
  end

  describe ".all" do
    it "新しい順に並び、RETENTION_DAYS より古いものは除外する" do
      old_token = described_class.create(now: now - ((FileTicketStore::RETENTION_DAYS + 1) * 86_400))
      older = described_class.create(now: now - 86_400)
      newest = described_class.create(now: now)

      tokens = described_class.all(now: now).map { |t| t["token"] }
      expect(tokens).to eq([newest, older])
      expect(tokens).not_to include(old_token)
    end
  end
end
