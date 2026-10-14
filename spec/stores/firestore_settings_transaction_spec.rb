# frozen_string_literal: true

require_relative "../support/firestore_sdk_transaction_context"

RSpec.describe "Firestore設定更新のSDK完了確認" do
  include_context "Firestore SDKのオフライントランザクション"

  [nil, false].each do |business_result|
    it "書込み成功時の業務結果 #{business_result.inspect} をそのまま返す" do
      result = store.update { |current| [current.merge("custom" => "changed"), business_result] }

      expect(result).to eq(business_result)
      expect(store.load.fetch("custom")).to eq("changed")
      expect(successful_commits).to eq(["offline-tx-1"])
    end

    it "書込なしの正常終了でも業務結果 #{business_result.inspect} をそのまま返す" do
      expect(store.update { |_current| [nil, business_result] }).to eq(business_result)

      expect(store.load.fetch("custom")).to eq("retained")
      expect(commit_attempts.fetch(0).fetch(:writes)).to be_empty
      expect(successful_commits).to eq(["offline-tx-1"])
    end
  end

  %i[invalid_get invalid_commit].each do |failure|
    context "競合後の再試行が #{failure} になる場合" do
      let(:retry_failure) { failure }

      [nil, true].each do |business_result|
        it "完了を確認できない業務結果 #{business_result.inspect} を返さず例外にする" do
          expect do
            store.update { |current| [current.merge("custom" => "changed"), business_result] }
          end.to raise_error(RuntimeError, "Firestore settings transaction completion could not be confirmed")

          expect(transaction_reads.size).to eq(2)
          expect(transaction_reads.last.read_write.retry_transaction).to eq("offline-tx-1")
          expect(commit_attempts.size).to eq(failure == :invalid_get ? 1 : 2)
          expect(successful_commits).to be_empty
          expect(store.load.fetch("custom")).to eq("retained")
        end
      end

      it "save も完了を確認できない場合に保存結果を返さない" do
        expect { store.save("custom" => "changed") }
          .to raise_error(RuntimeError, "Firestore settings transaction completion could not be confirmed")
        expect(successful_commits).to be_empty
        expect(store.load.fetch("custom")).to eq("retained")
      end
    end
  end

  context "競合後に更新判定が変わる場合" do
    let(:retry_failure) { :retry_success }
    let(:retry_settings) { initial_settings.merge("api_keys" => { "same" => { "digest" => "existing" } }) }

    it "初回の成功判定を持ち越さず、最後の書込なしの拒否結果を返す" do
      result = store.update do |current|
        current.key?("api_keys") ? [nil, :duplicate] : [current.merge("api_keys" => {}), nil]
      end

      expect(result).to eq(:duplicate)
      expect(commit_attempts.map { |attempt| attempt.fetch(:writes).size }).to eq([1, 0])
      expect(successful_commits).to eq(["offline-tx-2"])
    end
  end
end
