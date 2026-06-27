# frozen_string_literal: true

require_relative "stores/file_settings_store"

# 管理者が設定する「スケジュール調整可能な時間帯（営業時間）」などの設定ストアのファサード。
#
# 公開 API は変えず、STORE_BACKEND（file/firestore）で永続化の実装（アダプタ）を切り替える。
# 暗号鍵を持たないため backend は遅延選択する（configure 不要）。
module SettingsStore
  module_function

  # business_days は調整可能な曜日（Ruby の wday: 0=日〜6=土）。既定は平日（月〜金）。
  # lunch_* は昼休憩を確保する時間帯と必要分数（既定 11:00〜14:00 / 60 分）。
  # sync_window_days は Outlook 同期で今日から何日先まで取得するか（既定 30 日先）。
  DEFAULT = {
    "business_start" => "09:00",
    "business_end" => "18:00",
    "business_days" => [1, 2, 3, 4, 5],
    "lunch_start" => "11:00",
    "lunch_end" => "14:00",
    "lunch_minutes" => 60,
    "sync_window_days" => 30
  }.freeze

  def build_backend(name)
    case name
    when "file" then FileSettingsStore.new(defaults: DEFAULT)
    else raise "未対応の STORE_BACKEND: #{name}"
    end
  end

  def backend
    @backend ||= build_backend(ENV.fetch("STORE_BACKEND", "file"))
  end

  def load = backend.load
  def save(attrs) = backend.save(attrs)
end
