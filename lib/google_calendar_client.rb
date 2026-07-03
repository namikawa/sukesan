# frozen_string_literal: true

require "json"
require "time"
require "securerandom"
require "oauth2"
require_relative "event"

# Google Calendar API (v3) を呼び出すクライアント。
# OAuth2::AccessToken を受け取り、その認可で API を実行する。
class GoogleCalendarClient
  # 同じ event id が既に存在する（409）= 前回の試行で作成済み。呼び出し側が冪等に扱うための例外。
  class Conflict < StandardError; end

  CALENDAR_ID = "primary"
  BASE = "https://www.googleapis.com/calendar/v3"
  PAGE_SIZE = 2500
  MAX_PAGES = 50 # 暴走防止の backstop（現実的なデータでは到達前に完了する）

  def initialize(access_token)
    @token = access_token
  end

  # 指定期間のイベント一覧を取得する。繰り返し予定は singleEvents で展開する。
  # nextPageToken を辿って全ページを取得する。
  def list_events(time_min:, time_max:)
    items = []
    page_token = nil
    MAX_PAGES.times do
      body = fetch_events_page(time_min, time_max, page_token)
      items.concat(body["items"] || [])
      page_token = body["nextPageToken"]
      break if page_token.nil? || page_token.empty?
    end
    items.map { |item| build_event(item) }
  end

  # Google カレンダーへイベントを作成する。
  # attendees: 参加者メールアドレスの配列（招待メールは送らず参加者として登録するだけ）。
  # request_meet: true なら Google Meet のリンクを発行する。
  # 戻り値は作成された API レスポンス（JSON をパースしたハッシュ。Meet リンク取得に使う）。
  # id: を渡すとクライアント指定のイベント ID で作成する（決定的 ID による冪等再試行に使う）。
  # 既に同じ ID が存在する場合（409）は Conflict を送出する。
  def create_event(event, attendees: [], request_meet: false, id: nil)
    response = @token.post(
      "#{BASE}/calendars/#{CALENDAR_ID}/events",
      headers: { "Content-Type" => "application/json" },
      params: insert_params(request_meet),
      body: JSON.generate(create_payload(event, attendees, request_meet, id))
    )
    JSON.parse(response.body)
  rescue OAuth2::Error => e
    raise Conflict if e.response&.status == 409

    raise
  end

  # イベントを削除する。既に存在しない（404）・削除済み（410）の場合は成功扱いにする（冪等）。
  # sendUpdates=none でキャンセル通知は送らない。
  def delete_event(event_id)
    @token.delete("#{BASE}/calendars/#{CALENDAR_ID}/events/#{event_id}", params: { sendUpdates: "none" })
    true
  rescue OAuth2::Error => e
    return true if [404, 410].include?(e.response&.status)

    raise
  end

  # イベントの一部項目を更新する（仮押さえの確定で使用: 件名の prefix 除去・説明の差し替え・
  # 参加者/Google Meet の追加）。指定した項目だけを送る。戻り値は更新後の API レスポンス
  # （JSON をパースしたハッシュ。Meet リンク取得に使う）。
  def patch_event(event_id, summary: nil, description: nil, attendees: [], request_meet: false)
    response = @token.patch(
      "#{BASE}/calendars/#{CALENDAR_ID}/events/#{event_id}",
      headers: { "Content-Type" => "application/json" },
      params: insert_params(request_meet),
      body: JSON.generate(patch_payload(summary, description, attendees, request_meet))
    )
    JSON.parse(response.body)
  end

  # 作成レスポンスから Google Meet のリンクを取り出す（無ければ nil）。
  def self.meet_link(response)
    response["hangoutLink"] ||
      response.dig("conferenceData", "entryPoints")
              &.find { |entry| entry["entryPointType"] == "video" }&.dig("uri")
  end

  private

  def fetch_events_page(time_min, time_max, page_token)
    params = {
      timeMin: time_min.utc.iso8601,
      timeMax: time_max.utc.iso8601,
      singleEvents: true,
      orderBy: "startTime",
      maxResults: PAGE_SIZE
    }
    params[:pageToken] = page_token if page_token
    JSON.parse(@token.get("#{BASE}/calendars/#{CALENDAR_ID}/events", params: params).body)
  end

  def meet_create_request
    { createRequest: { requestId: SecureRandom.uuid, conferenceSolutionKey: { type: "hangoutsMeet" } } }
  end

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

  # events.insert のクエリパラメータ。sendUpdates=none で参加者への通知（招待メール）を送らない意図を明示する。
  def insert_params(request_meet)
    params = { sendUpdates: "none" }
    params[:conferenceDataVersion] = 1 if request_meet
    params
  end

  # events.patch に送る JSON ボディ（指定された項目のみ）。
  def patch_payload(summary, description, attendees, request_meet)
    payload = {}
    payload[:summary] = summary if summary
    payload[:description] = description if description
    payload[:attendees] = attendees.map { |email| { email: email } } unless attendees.empty?
    payload[:conferenceData] = meet_create_request if request_meet
    payload
  end

  # events.insert に送る JSON ボディを組み立てる（任意項目は指定があるときだけ含める）。
  def create_payload(event, attendees, request_meet, id)
    payload = event_payload(event)
    payload[:id] = id if id
    payload[:attendees] = attendees.map { |email| { email: email } } unless attendees.empty?
    payload[:conferenceData] = meet_create_request if request_meet
    payload
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
