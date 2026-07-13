# frozen_string_literal: true

require "time"
require "openssl"
require "token_cipher"
require "ticket_status"

if ENV["FIRESTORE_EMULATOR_HOST"]
  require "stores/firestore_client"
  require "stores/firestore_ticket_store"
end

RSpec.describe "FirestoreTicketStore", :firestore do
  let(:cipher) { TokenCipher.new("0" * 32) }
  let(:firestore) { FirestoreClient.build }
  let(:doc_id_key) { "test-doc-id-key" }
  let(:now) { Time.iso8601("2026-06-22T09:00:00+09:00") }
  subject(:store) { FirestoreTicketStore.new(cipher: cipher, firestore: firestore, doc_id_key: doc_id_key) }

  def doc_id(token) = OpenSSL::HMAC.hexdigest("SHA256", doc_id_key, token)

  # 各テスト前に tickets コレクションを空にする。
  before do
    firestore.col("tickets").get { |snapshot| snapshot.ref.delete }
  end

  it "発行したチケットは active で読み戻せる" do
    token = store.create(now: now)
    ticket = store.find(token)
    expect(TicketStatus.status(ticket, now: now)).to eq("active")
    expect(ticket["token"]).to eq(token)
  end

  it "use! は active のとき使用済みにし、入力値を保存する" do
    token = store.create(now: now)
    expect(store.use!(token, attrs: { "requester" => "山田", "title" => "打合せ" }, now: now)).to be(true)
    ticket = store.find(token)
    expect(TicketStatus.status(ticket, now: now)).to eq("used")
    expect(ticket).to include("requester" => "山田", "title" => "打合せ")
  end

  it "use! は二重使用を防ぐ（2回目は false）" do
    token = store.create(now: now)
    expect(store.use!(token, attrs: {}, now: now)).to be(true)
    expect(store.use!(token, attrs: {}, now: now)).to be(false)
  end

  it "期限切れトークンは使用できない" do
    token = store.create(now: now)
    later = now + (TicketStatus::DEFAULT_TTL_HOURS * 3600) + 1
    expect(store.use!(token, attrs: {}, now: later)).to be(false)
  end

  it "ttl_hours 付きで発行でき、選んだ期限まで使用できる（24 時間を超えても有効）" do
    token = store.create(now: now, ttl_hours: 168)
    expect(store.find(token)["ttl_hours"]).to eq(168)

    later = now + (72 * 3600) # 既定 24h なら期限切れの時刻
    expect(store.use!(token, attrs: {}, now: later)).to be(true)
  end

  it "reactivate! で使用済みから active へ戻し、保存値を消す" do
    token = store.create(now: now)
    store.use!(token, attrs: { "requester" => "山田" }, now: now)
    store.reactivate!(token, now: now)
    ticket = store.find(token)
    expect(TicketStatus.status(ticket, now: now)).to eq("active")
    expect(ticket).not_to have_key("requester")
  end

  it "revoke は active のとき無効化し、遷移前のチケットを返す" do
    token = store.create(now: now)
    expect(store.revoke(token, now: now)).to include("status" => "active")
    expect(TicketStatus.status(store.find(token), now: now)).to eq("revoked")
  end

  # 2 枠の仮押さえ済みチケットを作るヘルパ。
  def hold_ticket
    token = store.create(now: now)
    store.hold!(token, now: now, attrs: {
                  "requester" => "山田", "title" => "打合せ", "holder_key" => "holder-secret",
                  "holds" => [
                    { "event_id" => "ev1", "slot_start" => "2026-06-23T10:00:00+09:00",
                      "slot_end" => "2026-06-23T10:30:00+09:00" },
                    { "event_id" => "ev2", "slot_start" => "2026-06-24T14:00:00+09:00",
                      "slot_end" => "2026-06-24T14:30:00+09:00" }
                  ]
                })
    token
  end

  it "hold! で held になり、制御フィールドの status も held に更新される" do
    token = hold_ticket
    ticket = store.find(token)
    expect(TicketStatus.status(ticket, now: now)).to eq("held")
    expect(ticket["holds"].size).to eq(2)
    expect(firestore.doc("tickets/#{doc_id(token)}").get[:status]).to eq("held")
  end

  it "confirm_hold! は選択スロットで確定し、確定前の holds を返す（二重決定は nil）" do
    token = hold_ticket
    holds = store.confirm_hold!(token, slot_start: "2026-06-23T10:00:00+09:00",
                                       attrs: {}, now: now)
    expect(holds.map { |h| h["event_id"] }).to eq(%w[ev1 ev2])

    ticket = store.find(token)
    expect(TicketStatus.status(ticket, now: now)).to eq("used")
    expect(ticket["slot_start"]).to eq("2026-06-23T10:00:00+09:00")
    expect(ticket).not_to have_key("holder_key")

    expect(store.confirm_hold!(token, slot_start: "2026-06-24T14:00:00+09:00",
                                      attrs: {}, now: now)).to be_nil
  end

  it "remove_hold! は 1 件を取り除き、最後の 1 件で cancelled になる" do
    token = hold_ticket
    removed = store.remove_hold!(token, slot_start: "2026-06-23T10:00:00+09:00", now: now)
    expect(removed["event_id"]).to eq("ev1")
    expect(TicketStatus.status(store.find(token), now: now)).to eq("held")

    store.remove_hold!(token, slot_start: "2026-06-24T14:00:00+09:00", now: now)
    expect(TicketStatus.status(store.find(token), now: now)).to eq("cancelled")
  end

  it "cancel_hold! はすべて取りやめて cancelled にし、holds を返す" do
    token = hold_ticket
    expect(store.cancel_hold!(token, now: now).size).to eq(2)
    expect(TicketStatus.status(store.find(token), now: now)).to eq("cancelled")
  end

  it "仮押さえ中のチケットも revoke でき、holds を含む遷移前チケットを返す（kill switch 用）" do
    token = hold_ticket
    previous = store.revoke(token, now: now)
    expect(previous["holds"].size).to eq(2)
    expect(TicketStatus.status(store.find(token), now: now)).to eq("revoked")
  end

  it "held は held_at から 7 日で期限切れになる（発行 24 時間は超えても有効）" do
    token = hold_ticket
    within = now + (TicketStatus::DEFAULT_TTL_HOURS * 3600) + 3600
    expect(TicketStatus.held?(store.find(token), now: within)).to be(true)

    after_ttl = now + TicketStatus::HOLD_TTL_SECONDS + 60
    expect(store.confirm_hold!(token, slot_start: "2026-06-23T10:00:00+09:00",
                                      attrs: {}, now: after_ttl)).to be_nil
  end

  it "all は新しい順で、保存ドキュメントは暗号化され平文が露出しない" do
    older = store.create(now: now - 3600)
    newest = store.create(now: now)
    store.use!(newest, attrs: { "requester" => "山田太郎" }, now: now)

    tokens = store.all(now: now).map { |t| t["token"] }
    expect(tokens.first(2)).to eq([newest, older])

    enc = firestore.doc("tickets/#{doc_id(newest)}").get[:enc]
    expect(enc).not_to include("山田太郎")
  end

  it "purge_at は作成から 6 週間後（物理削除は TTL ポリシーに委譲）" do
    token = store.create(now: now)
    purge_at = firestore.doc("tickets/#{doc_id(token)}").get[:purge_at]
    expect(purge_at.to_i).to eq((now + (FirestoreTicketStore::PURGE_DAYS * 86_400)).to_i)
  end

  it "doc id に生 token を使わない（HMAC 化した値を使う）" do
    token = store.create(now: now)
    # 生 token のパスには存在せず、HMAC 化した doc id でのみ引ける。
    expect(firestore.doc("tickets/#{token}").get.exists?).to be(false)
    expect(firestore.doc("tickets/#{doc_id(token)}").get.exists?).to be(true)
    expect(store.find(token)["token"]).to eq(token)
  end
end
