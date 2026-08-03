# frozen_string_literal: true

# 書き込み系（/api/ への POST）に対するスコープ認可の検証。認可は before フィルタで一律に課すため、
# 代表として最小の書き込みエンドポイント（POST /api/v1/tickets）で確認する。
RSpec.describe "API キーのスコープ認可" do
  let(:read_key) { "r" * 64 }
  let(:write_key) { "w" * 64 }
  let(:legacy_key) { "l" * 64 }
  let(:created_at) { "2026-07-01T09:00:00+09:00" }
  let(:api_keys) do
    {
      "read-sys" => { "digest" => Digest::SHA256.hexdigest(read_key), "created_at" => created_at, "scope" => "read" },
      "write-sys" => { "digest" => Digest::SHA256.hexdigest(write_key), "created_at" => created_at,
                       "scope" => "write" },
      # scope 未保存＝スコープ導入前に発行された既存キー（read 扱いになること）。
      "legacy-sys" => { "digest" => Digest::SHA256.hexdigest(legacy_key), "created_at" => created_at }
    }
  end

  before do
    allow(SettingsStore).to receive(:load).and_return(SettingsStore::DEFAULT.merge("api_keys" => api_keys))
  end

  def auth(key)
    { "HTTP_AUTHORIZATION" => "Bearer #{key}" }
  end

  it "read キーの書き込み要求は 403（insufficient_scope）で、監査ログに api_scope_denied を残す" do
    allow(AuditLog).to receive(:record)
    post "/api/v1/tickets", {}, auth(read_key)

    expect(last_response.status).to eq(403)
    expect(JSON.parse(last_response.body)).to eq(
      "error" => { "code" => "insufficient_scope", "message" => "この操作には write 権限の API キーが必要です。" }
    )
    expect(last_response.headers["Content-Type"]).to include("application/json")
    expect(AuditLog).to have_received(:record).with(:api_scope_denied, ip: "127.0.0.1", target: "read-sys")
    expect(TicketStore.all).to be_empty # 認可で止まるためチケットは発行されない
  end

  it "scope 未保存の既存キーは read 扱いで 403（fail-closed）" do
    post "/api/v1/tickets", {}, auth(legacy_key)
    expect(last_response.status).to eq(403)
    expect(JSON.parse(last_response.body).dig("error", "code")).to eq("insufficient_scope")
  end

  it "write キーは書き込み要求を通す（CSRF トークン無しの POST でも弾かれない）" do
    post "/api/v1/tickets", {}, auth(write_key)
    expect(last_response.status).to eq(201)
    expect(JSON.parse(last_response.body)["status"]).to eq("active")
  end

  it "write キーは参照系も呼べる（write は read を包含する）" do
    allow(TokenStore).to receive(:load).and_return({ "access_token" => "fake", "expires_at" => 4_102_444_800 })
    stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })

    get "/api/v1/calendars/google/events", {}, auth(write_key)
    expect(last_response.status).to eq(200)
  end
end
