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

    # 読めないファイルを空として扱って発行すると、新しい 1 件だけの内容で上書きされ元のチケットが戻らない。
    it "当週のファイルが読めないときは発行を中止し、ファイルを上書きしない" do
      FileUtils.mkdir_p(ENV.fetch("TICKETS_DIR"))
      path = File.join(ENV.fetch("TICKETS_DIR"), "tickets-#{now.strftime('%G-W%V')}.json")
      File.write(path, "corrupted-not-json-not-encrypted")

      expect do
        expect { described_class.create(now: now) }.to raise_error(FileTicketStore::UnreadableBucket) { |e|
          # メッセージは固定文で、ファイルの内容・元の例外を持たない。
          expect(e.message).not_to include("corrupted")
          expect(e.cause).to be_nil
        }
      end.to output(/読み込み失敗 .*tickets-.*\.json: .*（書き込みを中止します）/).to_stderr
      expect(File.read(path)).to eq("corrupted-not-json-not-encrypted")

      # 参照系は従来どおり空として扱う。
      expect(described_class.find("anything", now: now)).to be_nil
      expect(described_class.all(now: now)).to eq([])
    end

    # 上の例（Base64 として読めない＝ArgumentError）以外の原因でも中止すること。復号に使う鍵を固定するため、
    # ファサードでなくアダプタを既知の鍵で直接作る（firestore_ticket_store_spec と同じ作り方）。
    context "当週のファイルが読めない原因ごと" do
      let(:cipher) { TokenCipher.new("0" * 32) }
      let(:store) { FileTicketStore.new(cipher: cipher, dir: ENV.fetch("TICKETS_DIR")) }
      let(:path) { File.join(ENV.fetch("TICKETS_DIR"), "tickets-#{now.strftime('%G-W%V')}.json") }

      before { FileUtils.mkdir_p(ENV.fetch("TICKETS_DIR")) }

      # content を当週のファイルに書き、発行が中止されて（warn は error_class の経路）バイト列が変わらないことを確かめる。
      def expect_create_aborted(content, error_class)
        File.binwrite(path, content)

        expect do
          expect { store.create(now: now) }.to raise_error(FileTicketStore::UnreadableBucket)
        end.to output(/: #{error_class}（書き込みを中止します）/).to_stderr
        expect(File.binread(path)).to eq(content)
      end

      it "暗号鍵の食い違い（別の鍵で暗号化した正しい JSON）では発行を中止し、ファイルを変えない" do
        content = TokenCipher.new("1" * 32).encrypt(JSON.generate({ "t" => { "token" => "t" } }))
        expect_create_aborted(content, OpenSSL::Cipher::CipherError)
      end

      it "復号後の JSON の破損（同じ鍵で JSON でない文字列を暗号化）では発行を中止し、ファイルを変えない" do
        expect_create_aborted(cipher.encrypt("not-json"), JSON::ParserError)
      end
    end

    it "発行を中止したときは古い週ファイルの掃除（prune!）も行わない" do
      FileUtils.mkdir_p(ENV.fetch("TICKETS_DIR"))
      old = now - (FileTicketStore::KEEP_WEEKS * 7 * 86_400) # 保持範囲の外（発行できていれば削除される週）
      old_path = File.join(ENV.fetch("TICKETS_DIR"), "tickets-#{old.strftime('%G-W%V')}.json")
      File.write(old_path, "old-bucket")
      File.write(File.join(ENV.fetch("TICKETS_DIR"), "tickets-#{now.strftime('%G-W%V')}.json"), "corrupted")

      expect do
        expect { described_class.create(now: now) }.to raise_error(FileTicketStore::UnreadableBucket)
      end.to output(/書き込みを中止します/).to_stderr
      expect(File.read(old_path)).to eq("old-bucket")
    end
  end

  # 状態遷移は token が見つかった（＝読めた）週ファイルにだけ書く。探索範囲に読めないファイルがあっても、
  # それを空として上書きしないこと（発行の厳格化と合わせて、読めないファイルが書き換わる経路が無いことを固定する）。
  describe "読めない週ファイルがあるときの状態遷移" do
    it "別の週にあるチケットの遷移（use! / revoke）は成功し、読めないファイルは変わらない" do
      last_week = now - (7 * 86_400)
      used = described_class.create(now: last_week, ttl_hours: 168)
      revoked = described_class.create(now: last_week, ttl_hours: 168)
      unreadable = File.join(ENV.fetch("TICKETS_DIR"), "tickets-#{now.strftime('%G-W%V')}.json")
      File.write(unreadable, "corrupted-not-json-not-encrypted")

      expect do
        expect(described_class.use!(used, attrs: { "requester" => "山田" }, now: now)).to be(true)
        expect(described_class.revoke(revoked, now: now)).to include("status" => "active")
      end.to output(/空として扱います/).to_stderr

      expect(File.read(unreadable)).to eq("corrupted-not-json-not-encrypted")
      statuses = described_class.all(now: now).to_h { |t| [t["token"], described_class.status(t, now: now)] }
      expect(statuses).to include(used => "used", revoked => "revoked")
    end
  end

  describe "週ファイルの掃除（発行時）" do
    def bucket_path(time) = File.join(ENV.fetch("TICKETS_DIR"), "tickets-#{time.strftime('%G-W%V')}.json")

    it "新しい週に発行した後で古い週の時刻で発行しても、新しい週のファイルとチケットは残る" do
      monday = Time.iso8601("2026-06-22T00:00:00+09:00")
      sunday = monday - 60 # 直前の日曜 23:59（週の変わり目で発行が重なった・時計が巻き戻った場合）
      newer = described_class.create(now: monday)
      older = described_class.create(now: sunday)

      expect(File.exist?(bucket_path(monday))).to be(true)
      expect(described_class.find(newer, now: monday)).not_to be_nil
      expect(described_class.find(older, now: monday)).not_to be_nil
    end

    it "保持する最も古い週（KEEP_WEEKS）より古い週のファイルは削除する" do
      outside = now - (FileTicketStore::KEEP_WEEKS * 7 * 86_400)
      oldest_kept = now - ((FileTicketStore::KEEP_WEEKS - 1) * 7 * 86_400)
      described_class.create(now: outside)
      described_class.create(now: oldest_kept)
      described_class.create(now: now)

      expect(File.exist?(bucket_path(outside))).to be(false)
      expect(File.exist?(bucket_path(oldest_kept))).to be(true)
      expect(File.exist?(bucket_path(now))).to be(true)
    end

    # キーは "%G-W%V" の文字列比較で前後を判定するため、ISO 週の年またぎ（2026 年は W53 まである）で確かめる。
    it "ISO 週の年またぎでも、保持する最も古い週より古い前年の週だけを削除する" do
      jan = Time.iso8601("2027-01-07T10:00:00+09:00") # 2027-W01。保持範囲は 2026-W49〜2027-W01
      kept = %w[2026-12-03 2026-12-24 2026-12-31].map { |d| Time.iso8601("#{d}T10:00:00+09:00") } # W49 / W52 / W53
      outside = Time.iso8601("2026-11-26T10:00:00+09:00") # 2026-W48
      expect(kept.map { |t| t.strftime("%G-W%V") }).to eq(%w[2026-W49 2026-W52 2026-W53])
      expect(outside.strftime("%G-W%V")).to eq("2026-W48")

      [outside, *kept].each { |t| described_class.create(now: t) }
      described_class.create(now: jan)

      expect(File.exist?(bucket_path(outside))).to be(false)
      kept.each { |t| expect(File.exist?(bucket_path(t))).to be(true) }
      expect(File.exist?(bucket_path(jan))).to be(true)
    end

    it "ISO 週の年またぎで新しい年の週に発行した後で前年の週の時刻で発行しても、新しい年の週のファイルは残る" do
      new_year_monday = Time.iso8601("2027-01-04T00:00:00+09:00") # 2027-W01
      last_sunday = new_year_monday - 60 # 2027-01-03 23:59＝2026-W53
      expect(last_sunday.strftime("%G-W%V")).to eq("2026-W53")
      newer = described_class.create(now: new_year_monday)
      described_class.create(now: last_sunday)

      expect(File.exist?(bucket_path(new_year_monday))).to be(true)
      expect(described_class.find(newer, now: new_year_monday)).not_to be_nil
    end

    it "正規の名前でないファイル（tickets-backup.json など）は削除しない" do
      FileUtils.mkdir_p(ENV.fetch("TICKETS_DIR"))
      backup = File.join(ENV.fetch("TICKETS_DIR"), "tickets-backup.json")
      File.write(backup, "manual backup")
      described_class.create(now: now)

      expect(File.read(backup)).to eq("manual backup")
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
      later = now + (TicketStatus::DEFAULT_TTL_HOURS * 3600) + 1
      expect(described_class.use!(token, attrs: {}, now: later)).to be(false)
    end

    it "ttl_hours 付きで発行すると、選んだ期限まで使用できる（既定の 24 時間を超えても有効）" do
      token = described_class.create(now: now, ttl_hours: 168)
      expect(described_class.find(token, now: now)["ttl_hours"]).to eq(168)

      later = now + (72 * 3600) # 既定 24h なら期限切れの時刻
      expect(described_class.use!(token, attrs: {}, now: later)).to be(true)
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

    it "SEARCH_WEEKS より古い期限切れの仮押さえも、一覧に並ぶ範囲（KEEP_WEEKS）なら無効化できる" do
      token = hold_ticket(at: now - (25 * 86_400)) # 25 日前に発行・仮押さえ＝期限切れ・既定の探索範囲（3 週）の外
      expect(described_class.find(token, now: now)).to be_nil
      listed = described_class.all(now: now).find { |t| t["token"] == token }
      expect(described_class.status(listed, now: now)).to eq("expired")

      previous = described_class.revoke(token, now: now)
      expect(previous["holds"].size).to eq(2)
      revoked = described_class.all(now: now).find { |t| t["token"] == token }
      expect(described_class.status(revoked, now: now)).to eq("revoked")
      expect(revoked).not_to have_key("holds")
    end
  end

  describe ".cancel_booking!" do
    # 予約済み（used）チケットを作るヘルパ。attrs は use! で保存する内容。
    def booked_ticket(attrs: { "requester" => "山田", "title" => "打合せ", "event_id" => "sukesanev1" })
      token = described_class.create(now: now)
      described_class.use!(token, attrs: attrs, now: now)
      token
    end

    it "予約済みチケットを取消し、遷移前のチケット（削除対象の event_id を含む）を返す" do
      token = booked_ticket
      previous = described_class.cancel_booking!(token, now: now)

      expect(previous["event_id"]).to eq("sukesanev1")
      ticket = described_class.find(token, now: now)
      expect(described_class.status(ticket, now: now)).to eq("cancelled")
      expect(ticket["cancelled_at"]).to eq(now.iso8601)
    end

    it "取消済みのチケットは再度取消できない（false）" do
      token = booked_ticket
      described_class.cancel_booking!(token, now: now)
      expect(described_class.cancel_booking!(token, now: now)).to be(false)
    end

    it "event_id 未保存の予約済みチケットは取消できない（false・event_id 保存前の既存チケット）" do
      token = booked_ticket(attrs: { "requester" => "山田", "title" => "打合せ" })
      expect(described_class.cancel_booking!(token, now: now)).to be(false)
      expect(described_class.status(described_class.find(token, now: now), now: now)).to eq("used")
    end

    it "SEARCH_WEEKS より古くても、一覧に並ぶ範囲（KEEP_WEEKS）なら取消できる" do
      created = now - (28 * 86_400) # 4 週間前＝遷移の既定探索範囲（3 週）の外だが一覧（30 日）には並ぶ
      token = described_class.create(now: created)
      described_class.use!(token, attrs: { "requester" => "山田", "event_id" => "sukesanev1" }, now: created)
      expect(described_class.all(now: now).map { |t| t["token"] }).to include(token)

      expect(described_class.cancel_booking!(token, now: now)).to include("event_id" => "sukesanev1")
      cancelled = described_class.all(now: now).find { |t| t["token"] == token }
      expect(described_class.status(cancelled, now: now)).to eq("cancelled")
    end

    it "未使用・仮押さえ中のチケットは取消できない（false）" do
      expect(described_class.cancel_booking!(described_class.create(now: now), now: now)).to be(false)
      expect(described_class.cancel_booking!(hold_ticket, now: now)).to be(false)
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
      later = now + (TicketStatus::DEFAULT_TTL_HOURS * 3600) + 3600 # 発行 25 時間後（held_at からは 7 日以内）
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

    it "決定したイベントの ID を event_id として保存する（取消＝cancel_booking! の対象にするため）" do
      token = hold_ticket
      described_class.confirm_hold!(token, slot_start: "2026-06-23T14:00:00+09:00", attrs: {}, now: now)

      expect(described_class.find(token, now: now)["event_id"]).to eq("ev2")
      expect(described_class.cancel_booking!(token, now: now)).to include("event_id" => "ev2")
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
      later = now + (TicketStatus::DEFAULT_TTL_HOURS * 3600) + 1
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
