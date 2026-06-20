# frozen_string_literal: true

# 2つのカレンダーのイベントを突き合わせ、Outlook 側にのみ存在するイベントを抽出する。
module EventDiffer
  module_function

  def outlook_only(google_events:, outlook_events:)
    google_keys = google_events.to_set(&:match_key)
    outlook_events.reject { |event| google_keys.include?(event.match_key) }
  end
end
