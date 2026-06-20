# frozen_string_literal: true

require "json"
require "fileutils"

# 管理者が設定する「スケジュール調整可能な時間帯（営業時間）」を
# JSON ファイルに永続化する。セッションと違い、サーバ再起動後も保持される。
module SettingsStore
  module_function

  PATH = File.expand_path("../data/settings.json", __dir__)
  # business_days は調整可能な曜日（Ruby の wday: 0=日〜6=土）。既定は平日（月〜金）。
  DEFAULT = {
    "business_start" => "09:00",
    "business_end" => "18:00",
    "business_days" => [1, 2, 3, 4, 5]
  }.freeze

  def load
    return DEFAULT.dup unless File.exist?(PATH)

    DEFAULT.merge(JSON.parse(File.read(PATH)))
  rescue JSON::ParserError
    DEFAULT.dup
  end

  def save(business_start:, business_end:, business_days:)
    data = {
      "business_start" => business_start,
      "business_end" => business_end,
      "business_days" => business_days
    }
    FileUtils.mkdir_p(File.dirname(PATH))
    File.write(PATH, JSON.generate(data))
    data
  end
end
