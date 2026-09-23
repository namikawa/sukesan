# frozen_string_literal: true

RSpec.describe "OAuth トークン更新の保存" do
  let(:google_hash) do
    { "access_token" => "google-old", "refresh_token" => "google-refresh-old", "expires_at" => 1,
      "scope" => "google-old-scope", "admin_email" => "admin@example.com" }
  end
  let(:microsoft_hash) do
    { "access_token" => "microsoft-old", "refresh_token" => "microsoft-refresh-old", "expires_at" => 1,
      "scope" => "microsoft-old-scope" }
  end
  let(:stored) { { google: google_hash, microsoft: microsoft_hash } }
  let(:oauth_helpers) { Object.new.extend(OAuthHelpers) }

  before do
    allow(TokenStore).to receive(:load) { |provider = :google| stored[provider] }
    allow(TokenStore).to receive(:with_lock).and_yield
    allow(TokenStore).to receive(:save) do |hash, provider|
      expect(hash.keys).to all(be_a(String))
      json = JSON.generate(hash)
      expect(json.scan('"scope":').length).to eq(1)
      stored[provider] = JSON.parse(json)
    end

    stub_request(:post, "https://oauth2.googleapis.com/token")
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { access_token: "google-new", expires_in: 3600, scope: "google-new-scope" }.to_json)
    stub_request(:post, %r{https://login\.microsoftonline\.com/.+/oauth2/v2\.0/token})
      .to_return(status: 200, headers: { "Content-Type" => "application/json" },
                 body: { access_token: "microsoft-new", refresh_token: "microsoft-refresh-new",
                         expires_in: 3600, scope: "microsoft-new-scope" }.to_json)
  end

  it "Google の更新結果を文字列キーで保存し、古い refresh token と管理者メールを保持する" do
    token = oauth_helpers.google_token

    expect(token.token).to eq("google-new")
    expect(stored[:google]).to include(
      "access_token" => "google-new", "refresh_token" => "google-refresh-old",
      "scope" => "google-new-scope", "admin_email" => "admin@example.com"
    )
    expect(stored[:google]["expires_at"]).to be > Time.now.to_i
  end

  it "Microsoft の refresh token ローテーションを保存する" do
    token = oauth_helpers.microsoft_token

    expect(token.token).to eq("microsoft-new")
    expect(stored[:microsoft]).to include(
      "access_token" => "microsoft-new", "refresh_token" => "microsoft-refresh-new",
      "scope" => "microsoft-new-scope"
    )
    expect(stored[:microsoft]["expires_at"]).to be > Time.now.to_i
  end

  it "期限切れトークンを更新した後、Google イベント API は新しいトークンで 200 を返す" do
    api_key = "k" * 64
    api_keys = { "test-sys" => { "digest" => Digest::SHA256.hexdigest(api_key), "scope" => "read" } }
    allow(SettingsStore).to receive(:load).and_return(SettingsStore::DEFAULT.merge("api_keys" => api_keys))
    stub_request(:get, %r{https://www\.googleapis\.com/calendar/v3/calendars/primary/events})
      .with(headers: { "Authorization" => "Bearer google-new" })
      .to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: { items: [] }.to_json)

    get "/api/v1/calendars/google/events", {}, "HTTP_AUTHORIZATION" => "Bearer #{api_key}"

    expect(last_response.status).to eq(200)
    expect(JSON.parse(last_response.body)["events"]).to eq([])
    expect(stored[:google]["access_token"]).to eq("google-new")
    expect(a_request(:get, %r{https://www\.googleapis\.com/calendar/v3/calendars/primary/events})
      .with(headers: { "Authorization" => "Bearer google-new" })).to have_been_made.once
  end
end
