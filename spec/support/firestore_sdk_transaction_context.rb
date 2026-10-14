# frozen_string_literal: true

require "stores/firestore_settings_store"

# アダプタ・SDKの読込、書込、再試行は実処理を通し、Firestoreの通信境界だけを差し替える。
RSpec.shared_context "Firestore SDKのオフライントランザクション" do
  let(:initial_settings) { { "custom" => "retained" } }
  let(:retry_settings) { initial_settings }
  let(:persisted_settings) { initial_settings.dup }
  let(:retry_failure) { nil }
  let(:service) do
    instance_double(Google::Cloud::Firestore::Service,
                    database_path: "projects/offline-test/databases/(default)", read_time_to_timestamp: nil)
  end
  let(:firestore) { Google::Cloud::Firestore::Client.new(service) }
  let(:store) { FirestoreSettingsStore.new(defaults: SettingsStore::DEFAULT, firestore: firestore) }
  let(:transaction_reads) { [] }
  let(:commit_attempts) { [] }
  let(:successful_commits) { [] }

  def sdk_snapshot(path, data, transaction_id)
    document = Google::Cloud::Firestore::V1::Document.new(
      name: path, fields: Google::Cloud::Firestore::Convert.hash_to_fields(data)
    )
    Google::Cloud::Firestore::V1::BatchGetDocumentsResponse.new(found: document, transaction: transaction_id)
  end

  before do
    # SDK標準のバックオフの待機だけを省き、再試行の制御自体は変更しない。
    allow(firestore).to receive(:sleep)
    allow(service).to receive(:get_documents) do |paths, transaction: nil, **|
      if transaction
        transaction_reads << transaction
        if transaction_reads.size == 2 && retry_failure == :invalid_get
          raise Google::Cloud::InvalidArgumentError, "transaction has expired"
        end

        data = transaction_reads.size == 1 ? initial_settings : retry_settings
        [sdk_snapshot(paths.fetch(0), data, "offline-tx-#{transaction_reads.size}")]
      else
        [sdk_snapshot(paths.fetch(0), persisted_settings, "")]
      end
    end
    allow(service).to receive(:commit) do |writes, transaction:|
      commit_attempts << { writes: writes, transaction: transaction }
      raise Google::Cloud::AbortedError, "injected conflict" if retry_failure && commit_attempts.size == 1
      raise Google::Cloud::InvalidArgumentError, "transaction has expired" if retry_failure == :invalid_commit

      writes.each do |write|
        persisted_settings.replace(Google::Cloud::Firestore::Convert.fields_to_hash(write.update.fields, firestore))
      end
      successful_commits << transaction
      Google::Cloud::Firestore::V1::CommitResponse.new
    end
  end
end
