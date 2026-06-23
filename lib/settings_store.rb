# frozen_string_literal: true

require "json"
require "fileutils"
require "securerandom"
require_relative "cross_process_lock"

# 管理者が設定する「スケジュール調整可能な時間帯（営業時間）」を
# JSON ファイルに永続化する。セッションと違い、サーバ再起動後も保持される。
module SettingsStore
  module_function

  PATH = File.expand_path("../data/settings.json", __dir__)
  # save の read-modify-write を直列化し、複数画面（/settings・/sync）からの同時保存で
  # 一部設定が巻き戻るのを防ぐ。読み取り（load）は原子的 rename 前提でロック不要。
  LOCK = CrossProcessLock.new("#{PATH}.lock")
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

  def load
    return DEFAULT.dup unless File.exist?(PATH)

    DEFAULT.merge(JSON.parse(File.read(PATH)))
  rescue JSON::ParserError
    DEFAULT.dup
  end

  # 指定した項目だけを既存設定にマージして保存する（未指定の項目は保持する）。
  # 設定の編集 UI が複数画面（/settings・/sync）に分かれても互いの値を消さない。
  # 0600・原子的書き込みで保存する（他のデータファイルと権限方針を揃える）。
  def save(attrs)
    LOCK.synchronize do
      data = load.merge(attrs.transform_keys(&:to_s))
      dir = File.dirname(PATH)
      FileUtils.mkdir_p(dir, mode: 0o700)
      tmp = File.join(dir, ".settings.#{SecureRandom.hex(8)}.tmp")
      File.write(tmp, JSON.generate(data))
      File.chmod(0o600, tmp)
      File.rename(tmp, PATH) # 同一ファイルシステム内での rename は原子的
      data
    end
  end
end
