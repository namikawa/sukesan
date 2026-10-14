# frozen_string_literal: true

require_relative "../support/oauth_concurrency_examples"
require "stores/firestore_token_store" if ENV["FIRESTORE_EMULATOR_HOST"]

RSpec.describe "ファイル保存の OAuth 操作の競合" do
  let(:store) { FileTokenStore.new(cipher: TokenCipher.new("0" * 32)) }
  include_examples "OAuth 操作の競合"
end

RSpec.describe "Firestore 保存の OAuth 操作の競合", :firestore do
  let(:firestore) { Google::Cloud::Firestore.new(project_id: "sukesan-spec-oauth-concurrency") }
  let(:store) { FirestoreTokenStore.new(cipher: TokenCipher.new("0" * 32), firestore: firestore) }
  include_examples "OAuth 操作の競合"
end
