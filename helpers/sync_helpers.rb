# frozen_string_literal: true

# Outlook 同期（管理者専用）を支えるヘルパ。
module SyncHelpers
  def time_window
    now = Time.now
    [now - (SYNC_WINDOW_PAST * 86_400), now + (SYNC_WINDOW_FUTURE * 86_400)]
  end

  def synced_keys
    session[:synced_keys] ||= []
  end
end
