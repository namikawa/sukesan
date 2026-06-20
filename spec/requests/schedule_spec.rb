# frozen_string_literal: true

RSpec.describe "予定作成 /schedule" do
  let(:token_hash) { { "access_token" => "fake", "expires_at" => 4_102_444_800 } }
  let(:settings) do
    { "business_start" => "09:00", "business_end" => "18:00", "business_days" => [1, 2, 3, 4, 5] }
  end
  # 2026-06-22 は月曜（営業日）。
  let(:valid_slot) { "2026-06-22T09:00:00+09:00/2026-06-22T09:30:00+09:00" }

  before do
    allow(TokenStore).to receive(:load).and_return(token_hash)
    allow(SettingsStore).to receive(:load).and_return(settings)
    stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })
  end

  it "CSRF トークンが無いと 403" do
    post "/schedule", title: "t", requester: "r", slot: valid_slot
    expect(last_response.status).to eq(403)
  end

  it "不正な slot 形式は 400" do
    post "/schedule", authenticity_token: csrf_token, title: "t", requester: "r", slot: "notatime"
    expect(last_response.status).to eq(400)
  end

  it "依頼者名が無いと 400" do
    post "/schedule", authenticity_token: csrf_token, title: "t", slot: valid_slot
    expect(last_response.status).to eq(400)
  end

  it "候補に無い時間帯（営業時間外）は 422" do
    post "/schedule", authenticity_token: csrf_token, title: "t", requester: "r",
                      slot: "2026-06-22T03:00:00+09:00/2026-06-22T04:00:00+09:00"
    expect(last_response.status).to eq(422)
  end

  it "正当な候補なら予定を作成して 302 を返す" do
    create = stub_request(:post, "https://www.googleapis.com/calendar/v3/calendars/primary/events")
             .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
    post "/schedule", authenticity_token: csrf_token, title: "打合せ", requester: "山田", slot: valid_slot
    expect(last_response.status).to eq(302)
    expect(create).to have_been_requested
  end
end
