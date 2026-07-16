# frozen_string_literal: true

RSpec.describe ScheduleHelpers do
  include ScheduleHelpers

  describe "#next_business_day" do
    let(:business_days) { [1, 2, 3, 4, 5] } # 月〜金

    it "翌営業日が平日の祝日（海の日 2026-07-20 月曜）ならスキップして翌火曜を返す" do
      # Date.today を固定し、実行日に依存しない決定的なテストにする。
      allow(Date).to receive(:today).and_return(Date.new(2026, 7, 19)) # 日曜
      # 翌日 2026-07-20（月）は海の日のため飛ばし、2026-07-21（火）を既定日にする。
      expect(next_business_day(business_days)).to eq(Date.new(2026, 7, 21))
    end

    it "曜日未設定なら無限ループを避けるため単純に翌日を返す" do
      allow(Date).to receive(:today).and_return(Date.new(2026, 7, 19))
      expect(next_business_day([])).to eq(Date.new(2026, 7, 20))
    end
  end
end
