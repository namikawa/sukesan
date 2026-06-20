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

require_relative "helpers/auth_helpers"
require_relative "helpers/oauth_helpers"
require_relative "helpers/format_helpers"
require_relative "helpers/settings_params_helpers"
require_relative "helpers/sync_helpers"
require_relative "helpers/schedule_helpers"

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
TokenStore.configure(Digest::SHA256.digest(token_key))

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
  redirect request.url.sub(%r{\Ahttp://}, "https://"), 308 if settings.production? && !request.secure?
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

# チェック対象として取得するイベントの期間（日数）。
SYNC_WINDOW_PAST = 1
SYNC_WINDOW_FUTURE = 60

# 公開フォーム（スケジュール調整）のスパム対策。IP ごとに 60 秒で 5 回まで。
SCHEDULE_LIMITER = RateLimiter.new(max: 5, window_seconds: 60)

# 空き時間検索（Google API を消費する）の濫用対策。IP ごとに 60 秒で 10 回まで。
SEARCH_LIMITER = RateLimiter.new(max: 10, window_seconds: 60)

# 管理者ログインのブルートフォース対策。IP ごとに 5 分で 10 回まで。
LOGIN_LIMITER = RateLimiter.new(max: 10, window_seconds: 300)

# 曜日の表示順とラベル（Ruby の wday: 0=日〜6=土）。月曜始まりで表示する。
WEEKDAY_LABELS = { 0 => "日", 1 => "月", 2 => "火", 3 => "水", 4 => "木", 5 => "金", 6 => "土" }.freeze
WEEKDAY_ORDER = [1, 2, 3, 4, 5, 6, 0].freeze

# 予定名・依頼者名の最大文字数。
# 営業日表示数・探索上限（MAX_BUSINESS_DAYS / MAX_SCAN_DAYS）は AvailabilitySearch に持つ。
MAX_TEXT_LENGTH = 100

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
  unless availability_search(SettingsStore.load).slot_available?(starts_at, ends_at)
    halt 422, "選択した時間帯は予約できません。お手数ですが再度空き時間をチェックしてください。"
  end

  # 二重登録を防ぐため、カレンダー登録より先に token を使用済みにする。
  # 同時送信で既に使われていれば false（登録は行わない）。
  consumed = TicketStore.use!(token, attrs: {
                                "requester" => requester, "title" => title,
                                "slot_start" => starts_at.iso8601, "slot_end" => ends_at.iso8601
                              })
  halt 409, "この URL は既に使用されています。" unless consumed

  begin
    event = Event.new(
      source: "google",
      title: "#{title} - #{requester} (from 調整ツール)",
      starts_at: starts_at,
      ends_at: ends_at,
      all_day: false,
      description: "依頼者: #{requester}"
    )
    GoogleCalendarClient.new(google_token).create_event(event)
  rescue StandardError
    # 登録に失敗したときは token を有効へ戻し、再試行できるようにする。
    TicketStore.reactivate!(token)
    halt 502, "予定の登録に失敗しました。お手数ですが、もう一度お試しください。"
  end

  session[:flash] = "#{requester} さんの「#{title}」を #{format_dt(event.starts_at)} に登録しました。"
  redirect "/t/#{token}"
end

# --- 管理者ログイン ---
post "/settings/login" do
  halt 429, "ログイン試行が多すぎます。しばらく時間をおいてからお試しください。" unless LOGIN_LIMITER.allow?(client_ip)

  if admin_password_valid?(params[:password].to_s)
    session.options[:renew] = true # セッション固定対策: ログイン時に session id を再生成
    session[:admin] = true
  else
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
    SettingsStore.save(**values)
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
  @events = (session[:outlook_only] || []).map { |h| Event.from_h(h) }
  @checked = session.key?(:outlook_only)
  erb :index
end

# --- Google OAuth（連携は管理者のみ。トークンは共有保存する） ---
get "/auth/google" do
  require_admin!
  redirect OAuthClients.google.auth_code.authorize_url(
    redirect_uri: google_redirect_uri,
    scope: "https://www.googleapis.com/auth/calendar.events",
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
  TokenStore.save(token.to_hash)
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
  session[:microsoft_token] = token.to_hash
  redirect "/sync"
end

post "/disconnect" do
  require_admin!
  session.delete(:microsoft_token)
  session.delete(:outlook_only)
  session.delete(:synced_keys)
  redirect "/sync"
end

# --- 差分チェック（管理者専用） ---
post "/check" do
  require_admin!
  halt 400, "Google と Outlook の両方の連携が必要です" unless google_connected? && microsoft_connected?

  time_min, time_max = time_window
  google_events = GoogleCalendarClient.new(google_token)
                                      .list_events(time_min: time_min, time_max: time_max)
  outlook_events = OutlookCalendarClient.new(microsoft_token)
                                        .list_events(time_min: time_min, time_max: time_max)

  outlook_only = EventDiffer.outlook_only(
    google_events: google_events, outlook_events: outlook_events
  )

  session[:outlook_only] = outlook_only.map(&:to_h)
  session[:synced_keys] = []
  redirect "/sync"
end

# --- 同期（選択したイベントのみ Google へ反映。管理者専用） ---
post "/sync" do
  require_admin!
  halt 400, "Google の連携が必要です" unless google_connected?

  selected = Array(params[:selected])
  events = (session[:outlook_only] || []).map { |h| Event.from_h(h) }
  client = GoogleCalendarClient.new(google_token)

  events.select { |event| selected.include?(event.match_key) }.each do |event|
    client.create_event(event)
    synced_keys << event.match_key unless synced_keys.include?(event.match_key)
  end
  session[:synced_keys] = synced_keys
  redirect "/sync"
end
