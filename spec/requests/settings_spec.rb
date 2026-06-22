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

  describe "POST /sync/settings（同期の取得期間）" do
    it "1〜365 なら保存する" do
      allow(SettingsStore).to receive(:save)
      post "/sync/settings", authenticity_token: csrf_token, sync_window_days: "14"
      expect(SettingsStore).to have_received(:save).with(hash_including(sync_window_days: 14))
    end

    it "範囲外（0）は保存しない" do
      allow(SettingsStore).to receive(:save)
      post "/sync/settings", authenticity_token: csrf_token, sync_window_days: "0"
      expect(SettingsStore).not_to have_received(:save)
    end
  end
end
