# frozen_string_literal: true

if ENV["FIRESTORE_EMULATOR_HOST"]
  require "stores/firestore_client"
  require "stores/firestore_settings_store"
end

RSpec.describe "FirestoreSettingsStore", :firestore do
  let(:defaults) do
    { "business_start" => "09:00", "business_end" => "18:00", "sync_window_days" => 30 }
  end
  let(:firestore) { FirestoreClient.build }
  let(:document) { "test_settings/app" }
  subject(:store) { FirestoreSettingsStore.new(defaults: defaults, firestore: firestore, document: document) }

  before { firestore.doc(document).delete }

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
end
