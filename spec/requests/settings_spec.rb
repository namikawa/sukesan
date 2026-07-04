# frozen_string_literal: true

RSpec.describe "設定保存" do
  before { login_admin! }

  describe "POST /settings（営業時間・昼休憩）" do
    let(:valid) do
      {
        business_start: "09:00", business_end: "18:00", business_days: ["1"],
        lunch_start: "11:00", lunch_end: "14:00", lunch_minutes: "60"
      }
    end

    it "正しい入力は保存する" do
      allow(SettingsStore).to receive(:save)
      post "/settings", valid.merge(authenticity_token: csrf_token)
      expect(SettingsStore).to have_received(:save)
    end

    it "開始 >= 終了は保存しない" do
      allow(SettingsStore).to receive(:save)
      post "/settings", valid.merge(authenticity_token: csrf_token, business_start: "18:00", business_end: "09:00")
      expect(SettingsStore).not_to have_received(:save)
    end
  end

  describe "POST /settings/google/disconnect" do
    it "revoke がタイムアウトしてもローカル削除を完了する" do
      allow(TokenStore).to receive(:load)
        .and_return({ "access_token" => "at", "refresh_token" => "rt", "expires_at" => 4_102_444_800 })
      allow(TokenStore).to receive(:clear)
      stub_request(:post, "https://oauth2.googleapis.com/revoke").to_timeout

      post "/settings/google/disconnect", authenticity_token: csrf_token
      expect(last_response.status).to eq(302)
      expect(TokenStore).to have_received(:clear)
      expect(a_request(:post, "https://oauth2.googleapis.com/revoke")).to have_been_made
    end
  end
end
