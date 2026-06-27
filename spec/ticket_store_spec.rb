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
    it "有効なトークンを無効化する" do
      token = described_class.create(now: now)
      expect(described_class.revoke(token, now: now)).to be(true)
      expect(described_class.status(described_class.find(token, now: now), now: now)).to eq("revoked")
    end

    it "使用済みのトークンは無効化できない" do
      token = described_class.create(now: now)
      described_class.use!(token, attrs: {}, now: now)
      expect(described_class.revoke(token, now: now)).to be(false)
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
