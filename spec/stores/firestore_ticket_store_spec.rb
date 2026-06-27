# frozen_string_literal: true

require "time"
require "token_cipher"
require "ticket_status"

if ENV["FIRESTORE_EMULATOR_HOST"]
  require "stores/firestore_client"
  require "stores/firestore_ticket_store"
end

RSpec.describe "FirestoreTicketStore", :firestore do
  let(:cipher) { TokenCipher.new("0" * 32) }
  let(:firestore) { FirestoreClient.build }
  let(:now) { Time.iso8601("2026-06-22T09:00:00+09:00") }
  subject(:store) { FirestoreTicketStore.new(cipher: cipher, firestore: firestore) }

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
    later = now + TicketStatus::TTL_SECONDS + 1
    expect(store.use!(token, attrs: {}, now: later)).to be(false)
  end

  it "reactivate! で使用済みから active へ戻し、保存値を消す" do
    token = store.create(now: now)
    store.use!(token, attrs: { "requester" => "山田" }, now: now)
    store.reactivate!(token, now: now)
    ticket = store.find(token)
    expect(TicketStatus.status(ticket, now: now)).to eq("active")
    expect(ticket).not_to have_key("requester")
  end

  it "revoke は active のときだけ無効化する" do
    token = store.create(now: now)
    expect(store.revoke(token, now: now)).to be(true)
    expect(TicketStatus.status(store.find(token), now: now)).to eq("revoked")
  end

  it "all は新しい順で、保存ドキュメントは暗号化され平文が露出しない" do
    older = store.create(now: now - 3600)
    newest = store.create(now: now)
    store.use!(newest, attrs: { "requester" => "山田太郎" }, now: now)

    tokens = store.all(now: now).map { |t| t["token"] }
    expect(tokens.first(2)).to eq([newest, older])

    enc = firestore.doc("tickets/#{newest}").get[:enc]
    expect(enc).not_to include("山田太郎")
  end
end
