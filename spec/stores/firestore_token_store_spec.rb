# frozen_string_literal: true

require "token_cipher"

if ENV["FIRESTORE_EMULATOR_HOST"]
  require "stores/firestore_client"
  require "stores/firestore_token_store"
end

RSpec.describe "FirestoreTokenStore", :firestore do
  let(:cipher) { TokenCipher.new("0" * 32) }
  let(:firestore) { FirestoreClient.build }
  subject(:store) { FirestoreTokenStore.new(cipher: cipher, firestore: firestore) }

  before do
    store.clear(:google)
    store.clear(:microsoft)
  end

  it "未保存なら nil を返す" do
    expect(store.load).to be_nil
  end

  it "保存したトークンを復号して読み戻す" do
    store.save({ "access_token" => "abc", "admin_email" => "owner@example.com" })
    expect(store.load).to include("access_token" => "abc", "admin_email" => "owner@example.com")
  end

  it "provider ごとに独立して保存・取得する" do
    store.save({ "access_token" => "g" }, :google)
    store.save({ "access_token" => "m" }, :microsoft)
    expect(store.load(:google)["access_token"]).to eq("g")
    expect(store.load(:microsoft)["access_token"]).to eq("m")
  end

  it "保存ドキュメントは暗号化され、平文トークンが露出しない" do
    store.save({ "access_token" => "secret-token" })
    raw = firestore.doc("tokens/google").get[:enc]
    expect(raw).to be_a(String)
    expect(raw).not_to include("secret-token")
  end

  it "clear で削除すると未連携になる" do
    store.save({ "access_token" => "abc" })
    store.clear
    expect(store.load).to be_nil
  end
end
