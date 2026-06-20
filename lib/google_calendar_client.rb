# frozen_string_literal: true

require "json"
require "time"
require_relative "event"

# Google Calendar API (v3) を呼び出すクライアント。
# OAuth2::AccessToken を受け取り、その認可で API を実行する。
class GoogleCalendarClient
  CALENDAR_ID = "primary"
  BASE = "https://www.googleapis.com/calendar/v3"

  def initialize(access_token)
    @token = access_token
  end

  # 指定期間のイベント一覧を取得する。繰り返し予定は singleEvents で展開する。
  def list_events(time_min:, time_max:)
    response = @token.get(
      "#{BASE}/calendars/#{CALENDAR_ID}/events",
      params: {
        timeMin: time_min.utc.iso8601,
        timeMax: time_max.utc.iso8601,
        singleEvents: true,
        orderBy: "startTime",
        maxResults: 2500
      }
    )
    items = JSON.parse(response.body)["items"] || []
    items.map { |item| build_event(item) }
  end

  # Google カレンダーへイベントを作成する。
  def create_event(event)
    @token.post(
      "#{BASE}/calendars/#{CALENDAR_ID}/events",
      headers: { "Content-Type" => "application/json" },
      body: JSON.generate(event_payload(event))
    )
  end

  private

  def build_event(item)
    Event.new(
      source: "google",
      external_id: item["id"],
      title: item["summary"],
      starts_at: parse_time(item["start"]),
      ends_at: parse_time(item["end"]),
      location: item["location"],
      all_day: !item.dig("start", "date").nil?
    )
  end

  def parse_time(node)
    return nil if node.nil?

    value = node["dateTime"] || node["date"]
    value && Time.parse(value)
  end

  def event_payload(event)
    payload = { summary: event.title, location: event.location }.merge(period(event))
    payload[:description] = event.description if event.description
    payload
  end

  def period(event)
    ends_at = event.ends_at || event.starts_at

    if event.all_day
      { start: { date: event.starts_at.utc.strftime("%F") }, end: { date: ends_at.utc.strftime("%F") } }
    else
      { start: { dateTime: event.starts_at.iso8601 }, end: { dateTime: ends_at.iso8601 } }
    end
  end
end
