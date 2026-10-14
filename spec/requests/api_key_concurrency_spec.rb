# frozen_string_literal: true

require_relative "../support/api_key_concurrency_examples"
require "stores/firestore_settings_store" if ENV["FIRESTORE_EMULATOR_HOST"]

RSpec.describe "ファイル保存の API キー並行更新" do
  let(:store) { FileSettingsStore.new(defaults: SettingsStore::DEFAULT) }
  before { allow(SettingsStore).to receive(:backend).and_return(store) }

  include_examples "API キーの並行更新"
end

RSpec.describe "Firestore 保存の API キー並行更新", :firestore do
  let(:firestore) { Google::Cloud::Firestore.new(project_id: "sukesan-spec-api-key-concurrency") }
  let(:document) { "test_settings/#{SecureRandom.hex(8)}" }
  let(:store) { FirestoreSettingsStore.new(defaults: SettingsStore::DEFAULT, firestore: firestore, document: document) }
  before { allow(SettingsStore).to receive(:backend).and_return(store) }
  after { firestore.doc(document).delete }

  include_examples "API キーの並行更新"

  # SDK の競合再試行は待ち時間だけで 5 秒を超え得るため、完了待ちだけ長くする。
  let(:key_completion_timeout) { 30 }
end
