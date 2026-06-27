# frozen_string_literal: true

require "sinatra"
require "json"
require "time"
require "date"
require "securerandom"
require "base64"
require "digest"
require "net/http"
require "rack/protection"
require "bcrypt"
require "logger"
require "fileutils"
require "dotenv/load"

require_relative "lib/event"
require_relative "lib/event_differ"
require_relative "lib/oauth_clients"
require_relative "lib/google_calendar_client"
require_relative "lib/outlook_calendar_client"
require_relative "lib/free_slot_finder"
require_relative "lib/settings_store"
require_relative "lib/token_store"
require_relative "lib/ticket_store"
require_relative "lib/rate_limiter"
require_relative "lib/availability_search"
require_relative "lib/booking_service"
require_relative "lib/cross_process_lock"

require_relative "helpers/auth_helpers"
require_relative "helpers/oauth_helpers"
require_relative "helpers/format_helpers"
require_relative "helpers/settings_params_helpers"
require_relative "helpers/sync_helpers"
require_relative "helpers/schedule_helpers"

# タイムゾーンを固定する（特定地域での運用前提。グローバル運用は想定しない）。
# APP_TIMEZONE（既定 Asia/Tokyo）をプロセスの TZ に適用し、サーバ OS の設定に依存させない。
# 以降の Time.now / Time.local / getlocal はすべてこのタイムゾーンで解釈・表示される。
APP_TIMEZONE = ENV.fetch("APP_TIMEZONE", "Asia/Tokyo")
ENV["TZ"] = APP_TIMEZONE

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", "3000").to_i

# ERB 出力を既定で HTML エスケープする（XSS 対策）。生 HTML を通す箇所は <%== %> を使う。
set :erb, escape_html: true

# 本番では詳細なエラー表示を抑止する（開発は Sinatra 既定の詳細表示のまま）。
configure :production do
  set :show_exceptions, false
  set :dump_errors, false
  set :raise_errors, false
end

# セッション署名用の秘密鍵。本番は必須（未設定・空なら起動時に失敗）。
# 開発・テストは未設定なら一時生成（プロセス再起動で無効化される）。
session_secret = ENV["SESSION_SECRET"].to_s
if session_secret.empty?
  raise "SESSION_SECRET must be set when APP_ENV/RACK_ENV=production" if settings.production?

  session_secret = SecureRandom.hex(64)
end
SESSION_SECRET = session_secret

# トークン暗号化の鍵。本番は必須、開発は未設定ならセッション鍵から導出する。
# 文字列を SHA-256 で 32 バイト（AES-256）に変換して使う。
token_key = ENV["TOKEN_ENCRYPTION_KEY"].to_s
if token_key.empty?
  raise "TOKEN_ENCRYPTION_KEY must be set when APP_ENV/RACK_ENV=production" if settings.production?

  token_key = SESSION_SECRET
end
token_cipher_key = Digest::SHA256.digest(token_key)
TokenStore.configure(token_cipher_key)
TicketStore.configure(token_cipher_key) # チケット（トークン・PII を含む）も同じ鍵で暗号化保存する

# 公開 URL。本番は必須（未設定だと OAuth redirect_uri やチケット URL が Host ヘッダ依存になり危険）。
# 開発・テストは未設定ならリクエストから組み立てる（base_url ヘルパ参照）。
if settings.production? && ENV["APP_BASE_URL"].to_s.strip.empty?
  raise "APP_BASE_URL must be set when APP_ENV/RACK_ENV=production"
end

# アクセスログは週次ローテーションする専用ファイル（log/access.log → access.log.YYYYMMDD）に出力する。
# Sinatra 既定の stderr 向けアクセスログは無効化し、二重出力を防ぐ。テストでは出力しない（log/ を汚さない）。
set :logging, false
unless settings.test?
  log_dir = File.expand_path("log", __dir__)
  FileUtils.mkdir_p(log_dir)
  ACCESS_LOG = Logger::LogDevice.new(File.join(log_dir, "access.log"), shift_age: "weekly")
  use Rack::CommonLogger, ACCESS_LOG
end

# セッションはサーバ側（メモリ）に保持する。Cookie 属性を強化し、Secure は本番のみ有効化。
use Rack::Session::Pool,
    key: "sukesan.session",
    secret: SESSION_SECRET,
    expire_after: 60 * 60 * 24,
    httponly: true,
    same_site: :lax,
    secure: settings.production?

# 全 POST に対する CSRF トークン検証（フォームに authenticity_token を埋め込む）。
use Rack::Protection::AuthenticityToken

# 本番では HTTPS を必須にする（開発は HTTP を許容）。
# 前段プロキシで TLS 終端する場合は X-Forwarded-Proto を設定すること。
before do
  # HTTPS 強制リダイレクト先は Host ヘッダ由来の request.url ではなく、ENV 固定の base_url
  # （本番では APP_BASE_URL）＋ パス/クエリで組み立て、Host 細工による誘導を防ぐ。
  redirect "#{base_url}#{request.fullpath}", 308 if settings.production? && !request.secure?
end

# Content-Security-Policy。スクリプト/スタイルは同一オリジンのみ（インライン不可）。
CSP_POLICY = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self'",
  "img-src 'self' data:",
  "form-action 'self'",
  "base-uri 'none'",
  "frame-ancestors 'none'",
  "object-src 'none'"
].join("; ")

# 共通のセキュリティヘッダを付与する。HSTS は本番（HTTPS 前提）のみ。
after do
  headers["Content-Security-Policy"] = CSP_POLICY
  headers["X-Content-Type-Options"] = "nosniff"
  headers["X-Frame-Options"] = "DENY"
  headers["Referrer-Policy"] = "no-referrer"
  headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains" if settings.production?
end

error do
  "エラーが発生しました。しばらくしてから再度お試しください。"
end

not_found do
  "ページが見つかりません。"
end

# Outlook 同期の日付範囲指定で許可する最大日数（開始〜終了の差）。日数指定の上限と揃える。
MAX_SYNC_RANGE_DAYS = 180

# 公開フォーム（スケジュール調整）のスパム対策。IP ごとに 60 秒で 5 回まで。
SCHEDULE_LIMITER = RateLimiter.new(max: 5, window_seconds: 60)

# 空き時間検索（Google API を消費する）の濫用対策。IP ごとに 60 秒で 10 回まで。
SEARCH_LIMITER = RateLimiter.new(max: 10, window_seconds: 60)

# 管理者ログインのブルートフォース対策。IP ごとに「失敗」5 分で 10 回まで（成功は消費しない）。
LOGIN_LIMITER = RateLimiter.new(max: 10, window_seconds: 300)

# 予約の臨界区間（空き再確認〜カレンダー登録）を直列化し、別トークン同士による同一枠の二重予約を防ぐロック。
# 実体は backend が用意する（file=flock のロックファイル / firestore=プロセス内 Mutex）。
BOOKING_LOCK = TicketStore.booking_lock

# 曜日の表示順とラベル（Ruby の wday: 0=日〜6=土）。月曜始まりで表示する。
WEEKDAY_LABELS = { 0 => "日", 1 => "月", 2 => "火", 3 => "水", 4 => "木", 5 => "金", 6 => "土" }.freeze
WEEKDAY_ORDER = [1, 2, 3, 4, 5, 6, 0].freeze

# 予定名・依頼者名の最大文字数。
# 営業日表示数・探索上限（MAX_BUSINESS_DAYS / MAX_SCAN_DAYS）は AvailabilitySearch に持つ。
MAX_TEXT_LENGTH = 100

# 参加者メールアドレスの最大件数と、ビデオ会議 URL の最大長（DoS・誤入力対策）。
MAX_ATTENDEES = 50
MAX_URL_LENGTH = 2048

# 発行済みワンタイム URL の一覧表示に使うステータス文言。
TICKET_STATUS_LABELS = {
  "active" => "有効", "used" => "使用済み", "expired" => "期限切れ", "revoked" => "無効化"
}.freeze

helpers AuthHelpers, OAuthHelpers, FormatHelpers, SettingsParamsHelpers, SyncHelpers, ScheduleHelpers

# --- トップ画面（利用案内のみ。調整はワンタイム URL から行う） ---
get "/" do
  @flash = session.delete(:flash)
  erb :home
end

# --- ワンタイム URL の調整画面（発行された token を持つ依頼者だけが利用） ---
get "/t/:token" do
  @token = params[:token].to_s
  @flash = session.delete(:flash)
  ticket = TicketStore.find(@token)

  # 無効・期限切れ・使用済み・存在しない token は案内ページを表示する。
  # 410 Gone を返す（404 は not_found ハンドラに横取りされるため使わない）。
  unless TicketStore.active?(ticket)
    @ticket_status = ticket ? TicketStore.status(ticket) : "missing"
    # 会議情報は「登録直後・本人セッション・当該 token」のときだけ表示する。
    completion = session[:completion]
    @completion = completion if completion && completion["token"] == @token
    status 410
    halt erb(:ticket_invalid)
  end

  @settings = SettingsStore.load
  @start_date = params[:start_date].to_s
  @end_date = params[:end_date].to_s
  @duration = params[:duration].to_s

  # 検索（Google API 消費）が実際に走る時だけレート制限する。ページ表示だけでは消費しない。
  inputs_present = !@start_date.empty? && !@end_date.empty? && !@duration.empty?
  if google_connected? && inputs_present
    if SEARCH_LIMITER.allow?(client_ip)
      result = availability_search(@settings).search(
        start_date: @start_date, end_date: @end_date, duration_minutes: @duration.to_i
      )
      @searched = result.searched
      @capped = result.capped
      @results = result.days
    else
      status 429
      @flash = "空き時間の検索が多すぎます。しばらく時間をおいてから再度お試しください。"
    end
  end

  # 初回アクセス時のフォーム既定値（翌営業日・30分）。検索はあくまで上の条件でのみ実行する。
  default_date = next_business_day(@settings["business_days"]).strftime("%F")
  @start_date = default_date if @start_date.empty?
  @end_date = default_date if @end_date.empty?
  @duration = "30" if @duration.empty?

  erb :schedule
end

# 選択した空き候補を管理者カレンダーへ登録する（ワンタイム URL からのみ）。
post "/schedule" do
  halt 429, "リクエストが多すぎます。しばらく時間をおいてからお試しください。" unless SCHEDULE_LIMITER.allow?(client_ip)

  token = params[:token].to_s
  ticket = TicketStore.find(token)
  halt 403, "この URL は無効か、期限切れです。管理者に新しい URL の発行を依頼してください。" unless TicketStore.active?(ticket)
  halt 400, "Google の連携が必要です" unless google_connected?

  title = params[:title].to_s.strip
  requester = params[:requester].to_s.strip
  starts_at, ends_at = parse_slot(params[:slot])

  halt 400, "依頼者名・予定名・希望の時間帯を入力してください" if title.empty? || requester.empty? || starts_at.nil?
  too_long = title.length > MAX_TEXT_LENGTH || requester.length > MAX_TEXT_LENGTH
  halt 400, "予定名・依頼者名が長すぎます（各 #{MAX_TEXT_LENGTH} 文字以内）" if too_long
  # 過去・直前すぎる時間帯は、空き再計算（Google 取得）の前に明示的に弾く。
  halt 422, "過去の時間帯は予約できません。お手数ですが再度空き時間をチェックしてください。" if AvailabilitySearch.too_soon?(starts_at)

  # 任意項目: 参加者メールアドレス・ビデオ会議 URL・Google Meet 発行。
  attendees = parse_attendees(params[:attendees])
  video_url = params[:video_url].to_s.strip
  request_meet = params[:request_meet].to_s == "1"

  halt 400, "参加者は最大 #{MAX_ATTENDEES} 件までです" if attendees.size > MAX_ATTENDEES
  halt 400, "参加者メールアドレスの形式が正しくありません" unless attendees.all? { |email| valid_email?(email) }
  halt 400, "ビデオ会議 URL の形式が正しくありません（http/https の URL）" unless video_url.empty? || valid_http_url?(video_url)
  halt 400, "ビデオ会議 URL の指定と Google Meet の発行は同時に指定できません" if request_meet && !video_url.empty?

  description = "依頼者: #{requester}"
  description += "\nビデオ会議: #{video_url}" unless video_url.empty?

  # 主催者（管理者自身）も参加者に含める。連携時に取得・保存したメールを使う
  # （取得できていなければ依頼者入力分のみ）。
  event_attendees = ([google_admin_email.to_s] + attendees).reject(&:empty?).uniq(&:downcase)

  # use! に保存する属性（任意項目は入力があるときだけ持たせる）。
  # 会議 URL（video_url / meet_link）はチケットに永続化しない（漏えい URL からの再露出を避ける）。
  ticket_attrs = {
    "requester" => requester, "title" => title,
    "slot_start" => starts_at.iso8601, "slot_end" => ends_at.iso8601
  }
  ticket_attrs["attendees"] = attendees unless attendees.empty?

  event = Event.new(
    source: "google",
    title: "#{title} - #{requester} (from 調整ツール)",
    starts_at: starts_at,
    ends_at: ends_at,
    all_day: false,
    description: description
  )

  # 予約の中核トランザクション（空き再確認→token 消費→Google 登録→失敗時ロールバック）は
  # BookingService に委譲する。HTTP ステータスへの写像だけルート側で行う。
  result = BookingService.new(
    lock: BOOKING_LOCK,
    availability: availability_search(SettingsStore.load),
    calendar_client: GoogleCalendarClient.new(google_token)
  ).call(token: token, event: event, ticket_attrs: ticket_attrs,
         attendees: event_attendees, request_meet: request_meet)

  case result.status
  when :slot_taken
    halt 422, "選択した時間帯は予約できません。お手数ですが再度空き時間をチェックしてください。"
  when :ticket_used
    halt 409, "この URL は既に使用されています。"
  when :api_failure
    halt 502, "予定の登録に失敗しました。お手数ですが、もう一度お試しください。"
  end

  # 会議情報は登録直後の本人セッションでだけ完了画面に表示する（チケットには残さない）。
  session[:completion] = { "token" => token, "meet_link" => result.meet_link, "video_url" => video_url }
  session[:flash] = "#{requester} さんの「#{title}」を #{format_dt(event.starts_at)} に登録しました。"
  redirect "/t/#{token}"
end

# --- 管理者ログイン ---
post "/settings/login" do
  # 失敗回数だけを数える。bcrypt 計算の前に弾くことで CPU 消耗型の総当たりも防ぐ。
  halt 429, "ログイン試行が多すぎます。しばらく時間をおいてからお試しください。" if LOGIN_LIMITER.exceeded?(client_ip)

  if admin_password_valid?(params[:password].to_s)
    session.options[:renew] = true # セッション固定対策: ログイン時に session id を再生成
    session[:admin] = true
  else
    LOGIN_LIMITER.record(client_ip) # 失敗時のみ記録（成功ログインは制限を消費しない）
    session[:flash] = "パスワードが正しくありません。"
  end
  redirect "/admin"
end

post "/settings/logout" do
  session.clear
  session.options[:drop] = true # ログアウト時はセッションを破棄する
  redirect "/admin"
end

# --- 管理画面（ワンタイム URL の発行・一覧。認証していなければログイン画面を表示） ---
get "/admin" do
  @flash = session.delete(:flash)
  return erb(:login) unless admin?

  @tickets = TicketStore.all
  erb :admin
end

# --- 設定（管理者専用：認証していなければログイン画面を表示） ---
get "/settings" do
  @flash = session.delete(:flash)
  return erb(:login) unless admin?

  @settings = SettingsStore.load
  erb :settings
end

# 1回限りのスケジュール調整 URL を発行する（管理者専用）。
post "/tickets" do
  require_admin!
  TicketStore.create
  session[:flash] = "ワンタイム URL を発行しました。"
  redirect "/admin"
end

# 発行済みワンタイム URL を手動で無効化する（管理者専用）。
post "/tickets/:token/revoke" do
  require_admin!
  TicketStore.revoke(params[:token].to_s)
  session[:flash] = "ワンタイム URL を無効化しました。"
  redirect "/admin"
end

post "/settings" do
  require_admin!
  values = settings_params
  if settings_valid?(values)
    SettingsStore.save(values)
    session[:flash] = "設定を保存しました。"
  else
    session[:flash] = "入力内容が正しくありません（時間は HH:MM・開始 < 終了、休憩は 0 分以上で入力してください）。"
  end
  redirect "/settings"
end

post "/settings/google/disconnect" do
  require_admin!
  revoke_google_token
  TokenStore.clear
  session[:flash] = "Google 連携を解除しました。"
  redirect "/settings"
end

# --- Outlook 同期（管理者専用） ---
get "/sync" do
  require_admin!
  @flash = session.delete(:flash)
  @settings = SettingsStore.load
  @test_mode = session[:sync_test_mode] == true
  @events = (session[:outlook_only] || []).map { |h| Event.from_h(h) }
  @checked = session.key?(:outlook_only)
  erb :index
end

# --- Google OAuth（連携は管理者のみ。トークンは共有保存する） ---
get "/auth/google" do
  require_admin!
  redirect OAuthClients.google.auth_code.authorize_url(
    # calendar.events に加え、主催者メール取得のため userinfo.email を要求する。
    redirect_uri: google_redirect_uri,
    scope: "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/userinfo.email",
    access_type: "offline",
    prompt: "consent",
    **begin_oauth!
  )
end

get "/auth/google/callback" do
  require_admin!
  verifier = oauth_verifier!
  halt 400, "連携がキャンセルされました。" if params[:code].to_s.empty?

  token = OAuthClients.google.auth_code.get_token(
    params[:code], redirect_uri: google_redirect_uri, code_verifier: verifier
  )
  # 連携時に主催者（管理者）のメールを取得し、トークンと一緒に保存する。
  TokenStore.save(token.to_hash.merge("admin_email" => fetch_google_email(token)))
  session[:flash] = "Google と連携しました。"
  redirect "/settings"
end

# --- Microsoft OAuth（Outlook 同期用。管理者のみ） ---
get "/auth/microsoft" do
  require_admin!
  redirect OAuthClients.microsoft.auth_code.authorize_url(
    redirect_uri: microsoft_redirect_uri,
    scope: "offline_access https://graph.microsoft.com/Calendars.Read",
    **begin_oauth!
  )
end

get "/auth/microsoft/callback" do
  require_admin!
  verifier = oauth_verifier!
  halt 400, "連携がキャンセルされました。" if params[:code].to_s.empty?

  token = OAuthClients.microsoft.auth_code.get_token(
    params[:code], redirect_uri: microsoft_redirect_uri, code_verifier: verifier
  )
  TokenStore.save(token.to_hash, :microsoft)
  redirect "/sync"
end

post "/disconnect" do
  require_admin!
  TokenStore.clear(:microsoft)
  session.delete(:outlook_only)
  session.delete(:synced_keys)
  redirect "/sync"
end

# --- 差分チェック（管理者専用） ---
# 取得範囲は日数（当日0:00起点）または日付範囲で指定。テストモードは差分表示のみ。
post "/check" do
  require_admin!
  halt 400, "Google と Outlook の両方の連携が必要です" unless google_connected? && microsoft_connected?

  window, error = resolve_sync_window(params)
  if error
    session[:flash] = error
    redirect "/sync"
  end

  time_min, time_max = window
  google_events = GoogleCalendarClient.new(google_token).list_events(time_min: time_min, time_max: time_max)
  outlook_events = OutlookCalendarClient.new(microsoft_token).list_events(time_min: time_min, time_max: time_max)

  session[:outlook_only] = EventDiffer.outlook_only(
    google_events: google_events, outlook_events: outlook_events
  ).map(&:to_h)
  session[:synced_keys] = []
  session[:sync_test_mode] = (params[:test_mode] == "1")
  redirect "/sync"
end

# --- 同期（選択したイベントのみ Google へ反映。管理者専用） ---
post "/sync" do
  require_admin!
  halt 400, "Google の連携が必要です" unless google_connected?
  # テストモードでチェックした直後は反映しない（誤適用防止）。
  if session[:sync_test_mode]
    session[:flash] = "テストモードのため反映しません。反映するにはテストモードを外して再チェックしてください。"
    redirect "/sync"
  end

  selected = Array(params[:selected])
  events = (session[:outlook_only] || []).map { |h| Event.from_h(h) }
  client = GoogleCalendarClient.new(google_token)

  events.select { |event| selected.include?(event.match_key) }.each do |event|
    next if synced_keys.include?(event.match_key) # 既に反映済みはサーバ側でスキップ（UI 依存せず冪等化）

    client.create_event(event)
    synced_keys << event.match_key
  end
  session[:synced_keys] = synced_keys
  redirect "/sync"
end
