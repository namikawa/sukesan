# frozen_string_literal: true

require "stores/firestore_settings_store" if ENV["FIRESTORE_EMULATOR_HOST"]

RSpec.describe "Firestore に保存した API キー", :firestore do
  let(:firestore) { Google::Cloud::Firestore.new(project_id: "sukesan-spec-api-keys") }
  let(:document) { "test_settings/#{SecureRandom.hex(8)}" }
  let(:store) { FirestoreSettingsStore.new(defaults: SettingsStore::DEFAULT, firestore: firestore, document: document) }

  before { allow(SettingsStore).to receive(:backend).and_return(store) }
  after { firestore.doc(document).delete }

  def issue_key(label, scope:)
    post "/settings/api_keys", authenticity_token: csrf_token, label: label, scope: scope
    expect(last_response.status).to eq(302)
    follow_redirect!
    key = last_response.body[/id="new-api-key">([0-9a-f]{64})</, 1]
    expect(key).not_to be_nil
    key
  end

  it "発行・再読出し後も認証と scope を使え、一方の削除後も残りのキーは使える" do
    login_admin!
    read_key = issue_key("reader", scope: "read")
    write_key = issue_key("writer", scope: "write")
    keys = store.load.fetch("api_keys")
    SettingsStore.save("business_start" => "10:00")
    expect(store.load.fetch("api_keys")).to eq(keys)

    read_auth = { "HTTP_AUTHORIZATION" => "Bearer #{read_key}" }
    write_auth = { "HTTP_AUTHORIZATION" => "Bearer #{write_key}" }
    get "/api/v1/tickets", {}, read_auth
    expect(last_response.status).to eq(200)
    post "/api/v1/tickets", {}, read_auth
    expect(last_response.status).to eq(403)
    post "/api/v1/tickets", {}, write_auth
    expect(last_response.status).to eq(201)
    expect(keys.keys).to match_array(%w[reader writer])
    expect(keys.fetch("reader")).to include("digest" => Digest::SHA256.hexdigest(read_key), "scope" => "read")
    expect(keys.fetch("writer")).to include("digest" => Digest::SHA256.hexdigest(write_key), "scope" => "write")
    expect(keys.values.map { |entry| entry.fetch("created_at") }).to all(be_a(String))

    # 認証ヘッダは次の管理画面リクエストへ持ち越さず、管理者セッションと CSRF で削除する。
    post "/settings/api_keys/delete", authenticity_token: csrf_token, label: "reader"
    expect(last_response.status).to eq(302)
    expect(store.load.fetch("api_keys")).to eq("writer" => keys.fetch("writer"))
    get "/api/v1/tickets", {}, read_auth
    expect(last_response.status).to eq(401)
    get "/api/v1/tickets", {}, write_auth
    expect(last_response.status).to eq(200)
  end
end
