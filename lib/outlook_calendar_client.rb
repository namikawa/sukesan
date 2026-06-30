# frozen_string_literal: true

require "json"
require "time"
require "uri"
require_relative "event"

# Microsoft Graph API 経由で Outlook カレンダーを読み取るクライアント。
# OAuth2::AccessToken を受け取り、その認可で API を実行する。
class OutlookCalendarClient
  BASE = "https://graph.microsoft.com/v1.0"
  PAGE_SIZE = 250
  MAX_PAGES = 50 # 暴走防止の backstop（現実的なデータでは到達前に完了する）

  def initialize(access_token)
    @token = access_token
  end

  # 指定期間のイベント一覧を取得する。calendarView は繰り返し予定も展開して返す。
  # @odata.nextLink（次ページの完全 URL）を辿って全ページを取得する。
  def list_events(time_min:, time_max:)
    items = []
    url = "#{BASE}/me/calendarView"
    opts = initial_request_opts(time_min, time_max)
    MAX_PAGES.times do
      body = JSON.parse(@token.get(url, opts).body)
      items.concat(body["value"] || [])
      url = next_page_url(body)
      break if url.nil?

      # 次ページの nextLink はクエリを含むため params は付けず、ヘッダのみ引き継ぐ。
      opts = { headers: opts[:headers] }
    end
    items.map { |item| build_event(item) }
  end

  private

  # 次ページの URL を返す（無ければ nil）。nextLink は Graph が返す完全 URL を辿る仕様。
  def next_page_url(body)
    url = body["@odata.nextLink"]
    return nil if url.nil? || url.empty?
    raise "想定外の @odata.nextLink: #{url}" unless valid_next_link?(url)

    url
  end

  # bearer トークンを付けて辿るため、graph.microsoft.com の v1.0 配下の https URL だけを許可する
  # （万一の応答汚染でアクセストークンを外部へ送らないための防御）。
  def valid_next_link?(url)
    uri = URI(url)
    uri.scheme == "https" && uri.host == "graph.microsoft.com" && uri.path.start_with?("/v1.0/")
  rescue URI::InvalidURIError
    false
  end

  def initial_request_opts(time_min, time_max)
    {
      # Prefer ヘッダで日時を UTC で返すよう指定する。
      headers: { "Prefer" => 'outlook.timezone="UTC"' },
      params: {
        startDateTime: time_min.utc.iso8601,
        endDateTime: time_max.utc.iso8601,
        "$top" => PAGE_SIZE,
        "$orderby" => "start/dateTime"
      }
    }
  end

  def build_event(item)
    Event.new(
      source: "outlook",
      external_id: item["id"],
      title: item["subject"],
      starts_at: parse_time(item["start"]),
      ends_at: parse_time(item["end"]),
      location: item.dig("location", "displayName"),
      all_day: item["isAllDay"] == true,
      cancelled: item["isCancelled"] == true
    )
  end

  def parse_time(node)
    return nil if node.nil? || node["dateTime"].nil?

    # Prefer ヘッダで UTC を指定しているため、UTC として解釈する。
    Time.parse("#{node['dateTime']} UTC")
  end
end
