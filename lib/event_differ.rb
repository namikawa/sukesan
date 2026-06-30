# frozen_string_literal: true

# 2つのカレンダーのイベントを突き合わせ、Outlook 側にのみ存在するイベントを抽出する。
module EventDiffer
  module_function

  def outlook_only(google_events:, outlook_events:)
    # Google 側の突き合わせキー集合を Hash で持ち（O(1) 参照）、Outlook 側で存在しないものを残す。
    # キャンセル済み（isCancelled）の Outlook イベントは同期対象外。
    google_keys = google_events.to_h { |event| [event.match_key, true] }
    outlook_events.reject { |event| event.cancelled || google_keys.key?(event.match_key) }
  end
end
