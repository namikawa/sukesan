# frozen_string_literal: true

# Outlook 同期（管理者専用）を支えるヘルパ。
module SyncHelpers
  def time_window
    now = Time.now
    future_days = SettingsStore.load["sync_window_days"]
    [now - (SYNC_WINDOW_PAST * 86_400), now + (future_days * 86_400)]
  end

  def synced_keys
    session[:synced_keys] ||= []
  end
end
