# frozen_string_literal: true

require "json"
require "time"
require_relative "event"

# Microsoft Graph API 経由で Outlook カレンダーを読み取るクライアント。
# OAuth2::AccessToken を受け取り、その認可で API を実行する。
class OutlookCalendarClient
  BASE = "https://graph.microsoft.com/v1.0"

  def initialize(access_token)
    @token = access_token
  end

  # 指定期間のイベント一覧を取得する。calendarView は繰り返し予定も展開して返す。
  def list_events(time_min:, time_max:)
    response = @token.get(
      "#{BASE}/me/calendarView",
      params: {
        startDateTime: time_min.utc.iso8601,
        endDateTime: time_max.utc.iso8601,
        "$top" => 250,
        "$orderby" => "start/dateTime"
      },
      # Prefer ヘッダで日時を UTC で返すよう指定する。
      headers: { "Prefer" => 'outlook.timezone="UTC"' }
    )
    items = JSON.parse(response.body)["value"] || []
    items.map { |item| build_event(item) }
  end

  private

  def build_event(item)
    Event.new(
      source: "outlook",
      external_id: item["id"],
      title: item["subject"],
      starts_at: parse_time(item["start"]),
      ends_at: parse_time(item["end"]),
      location: item.dig("location", "displayName"),
      all_day: item["isAllDay"] == true
    )
  end

  def parse_time(node)
    return nil if node.nil? || node["dateTime"].nil?

    # Prefer ヘッダで UTC を指定しているため、UTC として解釈する。
    Time.parse("#{node['dateTime']} UTC")
  end
end
