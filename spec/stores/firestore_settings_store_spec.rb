# frozen_string_literal: true

require_relative "../support/settings_update_examples"

if ENV["FIRESTORE_EMULATOR_HOST"]
  require "stores/firestore_client"
  require "stores/firestore_settings_store"
end

RSpec.describe "FirestoreSettingsStore", :firestore do
  let(:defaults) do
    { "business_start" => "09:00", "business_end" => "18:00", "sync_window_days" => 30 }
  end
  let(:firestore) { FirestoreClient.build }
  let(:document) { "test_settings/#{SecureRandom.hex(8)}" }
  subject(:store) { FirestoreSettingsStore.new(defaults: defaults, firestore: firestore, document: document) }

  before { firestore.doc(document).delete }
  after { firestore.doc(document).delete }

  def persisted_revision = firestore.doc(document).get.updated_at

  include_examples "設定の排他更新"

  it "未保存なら既定値を返す" do
    expect(store.load).to eq(defaults)
  end

  it "指定項目だけをマージ保存し、未指定項目は既定値を保つ" do
    store.save(business_start: "10:00")
    expect(store.load).to include("business_start" => "10:00", "business_end" => "18:00", "sync_window_days" => 30)
  end

  it "複数回の部分保存で他項目が巻き戻らない" do
    store.save(business_start: "10:00")
    store.save(sync_window_days: 14)
    expect(store.load).to include("business_start" => "10:00", "sync_window_days" => 14)
  end

  it "保存済み API キーのラベルと全項目を文字列キーで読み戻し、他項目の部分保存でも保つ" do
    keys = {
      "reader" => { "digest" => "r" * 64, "scope" => "read", "created_at" => "2026-10-15T09:00:00+09:00" },
      "writer" => { "digest" => "w" * 64, "scope" => "write", "created_at" => "2026-10-15T10:00:00+09:00" }
    }
    store.save("api_keys" => keys)
    expect(store.load.fetch("api_keys")).to eq(keys)

    saved = store.save("business_start" => "10:00")
    expect(saved.fetch("api_keys")).to eq(keys)
    expect(store.load).to include("business_start" => "10:00", "api_keys" => keys)
  end

  it "配列内のネストした Hash も文字列キーに揃え、日時・数値・真偽値・nil の型を保つ" do
    values = { "time" => Time.utc(2026, 10, 15, 9), "integer" => 7, "float" => 1.5,
               "true" => true, "false" => false, "null" => nil }
    records = [{ "nested" => values }]
    store.save("records" => records)

    expect(store.load.fetch("records")).to eq(records)
    expect(store.load.dig("records", 0, "nested", "time")).to be_a(Time)
  end
end

RSpec.describe "Firestore 設定更新のトランザクション再試行", :firestore do
  let(:firestore) { double("firestore", doc: double("document")) }
  let(:store) { FirestoreSettingsStore.new(defaults: {}, firestore: firestore) }

  it "中断された試行の成功結果を持ち越さず、最後の試行の拒否結果を返す" do
    initial = double("initial", exists?: false)
    latest = double("latest", exists?: true, data: { api_keys: { same: { digest: "existing" } } })
    aborted = double("aborted transaction", get: initial, set: nil)
    committed = double("committed transaction", get: latest, set: nil)
    allow(firestore).to receive(:transaction) do |&block|
      block.call(aborted)
      block.call(committed)
    end

    result = store.update do |current|
      current.key?("api_keys") ? [nil, :duplicate] : [{ "api_keys" => {} }, :issued]
    end

    expect(result).to eq(:duplicate)
    expect(aborted).to have_received(:set).once
    expect(committed).not_to have_received(:set)
  end

  it "commit が失敗したら更新結果を返さず例外を伝播する" do
    tx = double("transaction", get: double(exists?: false), set: nil)
    allow(firestore).to receive(:transaction) do |&block|
      block.call(tx)
      raise "commit failed"
    end

    expect { store.update { |current| [current.merge("custom" => true), :issued] } }
      .to raise_error(RuntimeError, "commit failed")
  end
end
