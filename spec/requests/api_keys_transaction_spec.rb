# frozen_string_literal: true

require_relative "../support/firestore_sdk_transaction_context"

RSpec.describe "APIキー画面のFirestore更新完了確認" do
  include_context "Firestore SDKのオフライントランザクション"

  let(:initial_settings) do
    { "api_keys" => { "existing" => { "digest" => "fake-digest", "scope" => "read" } } }
  end

  # 本番と同じ500ハンドラを検証し、テスト環境の例外伝播設定は終了時に戻す。
  around do |example|
    original_raise_errors = app.raise_errors
    app.set :raise_errors, false
    example.run
  ensure
    app.set :raise_errors, original_raise_errors
  end

  before do
    allow(SettingsStore).to receive(:backend).and_return(store)
    allow(SettingsStore).to receive(:update).and_call_original
    allow(AuditLog).to receive(:record)
    login_admin!
  end

  %i[invalid_get invalid_commit].each do |failure|
    context "競合後の再試行が #{failure} になる場合" do
      let(:retry_failure) { failure }

      { "/settings/api_keys" => "new-system", "/settings/api_keys/delete" => "existing" }.each do |path, label|
        it "#{path} は500を返し、成功の監査・通知・生キーの表示とセッション格納を行わない", :aggregate_failures do
          post path, authenticity_token: csrf_token, label: label

          expect(last_response.status).to eq(500)
          expect(last_response.body).to include("エラーが発生しました")
          expect(last_response.body).not_to include('id="new-api-key"')
          expect(last_request.env.fetch("rack.session")[:new_api_key]).to be_nil
          expect(last_request.env.fetch("rack.session")[:flash]).to be_nil
          expect(AuditLog).not_to have_received(:record).with(:api_key_issued, anything)
          expect(AuditLog).not_to have_received(:record).with(:api_key_revoked, anything)
          expect(successful_commits).to be_empty
          expect(store.load.fetch("api_keys")).to eq(initial_settings.fetch("api_keys"))

          get "/settings"
          expect(last_response.body).not_to include('id="new-api-key"', "API キーを発行しました", "API キーを削除しました")
        end
      end
    end
  end
end
