# frozen_string_literal: true

require "sinatra"
require "json"
require "time"
require "date"
require "securerandom"
require "base64"
require "digest"
require "openssl"
require "net/http"
require "rack/protection"
require "rack/session/cookie"
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
require_relative "lib/hold_service"
require_relative "lib/cross_process_lock"
require_relative "lib/masked_access_logger"
require_relative "lib/audit_log"

require_relative "helpers/auth_helpers"
require_relative "helpers/oauth_helpers"
require_relative "helpers/format_helpers"
require_relative "helpers/settings_params_helpers"
require_relative "helpers/sync_helpers"
require_relative "helpers/schedule_helpers"
require_relative "helpers/hold_helpers"
require_relative "helpers/api_helpers"

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
# Rack::Session::Cookie は 64 文字以上を要求するため、設定値が短い場合も起動失敗させる。
session_secret = ENV["SESSION_SECRET"].to_s
if session_secret.empty?
  raise "SESSION_SECRET must be set when APP_ENV/RACK_ENV=production" if settings.production?

  session_secret = SecureRandom.hex(64)
elsif session_secret.length < 64
  raise "SESSION_SECRET must be at least 64 characters (Rack::Session::Cookie requirement)"
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

# 決定的な Google イベント ID を作るための HMAC 鍵（暗号鍵から用途別に派生）。
# token から ID を決定的に導き、再試行時の重複作成を Google 側の一意制約で防ぐ（BookingService 参照）。
EVENT_ID_KEY = OpenSSL::HMAC.digest("SHA256", token_cipher_key, "sukesan-event-id")

# アクセスログで /t/<token> を相関可能な短縮 ID に置換するための HMAC 鍵（暗号鍵から用途別に派生）。
# 生の bearer token をログに残さない（MaskedAccessLogger 参照）。
LOG_TOKEN_ID_KEY = OpenSSL::HMAC.digest("SHA256", token_cipher_key, "sukesan-log-token-id")

# 公開 URL。本番は必須（未設定だと OAuth redirect_uri やチケット URL が Host ヘッダ依存になり危険）。
# 開発・テストは未設定ならリクエストから組み立てる（base_url ヘルパ参照）。
if settings.production? && ENV["APP_BASE_URL"].to_s.strip.empty?
  raise "APP_BASE_URL must be set when APP_ENV/RACK_ENV=production"
end

# Google OAuth のクレデンシャル。本番は必須（未設定だと保存済みトークンの利用時＝公開ページで
# 実行時 500 になるため、fail-fast で起動時に失敗させる）。Google 連携はアプリの中核機能。
# Microsoft は Outlook 同期を使わない運用があり得るため対象外（連携操作時にのみ必要）。
if settings.production? && (ENV["GOOGLE_CLIENT_ID"].to_s.empty? || ENV["GOOGLE_CLIENT_SECRET"].to_s.empty?)
  raise "GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET must be set when APP_ENV/RACK_ENV=production"
end

# 同一マシン上の他システム向け API のキー（"ラベル:キー" のカンマ区切り）。
# 未設定なら nil ＝ API 無効（/api/ 配下は 404）。設定時は起動時に形式を検証し、不正なら起動失敗させる。
CALENDAR_API_KEYS = ApiHelpers.parse_api_keys(ENV.fetch("CALENDAR_API_KEYS", nil))

# アクセスログの出力先は環境で切り替える。
# - LOG_TO_STDOUT=true: $stdout へ出す（Cloud Run などコンテナ環境。プラットフォームが Cloud Logging に集約する。
#   揮発ファイルに書いて取りこぼすのを防ぐ）。
# - 未設定（既定）: 週次ローテーションする専用ファイル（log/access.log → access.log.YYYYMMDD）。ローカル/VM 向け。
# Sinatra 既定の stderr 向けアクセスログは無効化し、二重出力を防ぐ。テストでは出力しない（log/ を汚さない）。
# 週次ローテーションのログデバイスを 0600 で用意する。ローテーション直後の新ファイルは
# 既定権限に戻るが、次回起動時の chmod で回収する（アクセスログの主対策はマスキング）。
def weekly_log_device(path)
  device = Logger::LogDevice.new(path, shift_age: "weekly")
  File.chmod(0o600, path) if File.owned?(path)
  device
end

set :logging, false
unless settings.test?
  if ENV["LOG_TO_STDOUT"] == "true"
    $stdout.sync = true # コンテナログに即時反映させる（バッファ滞留で取りこぼさない）
    access_log = $stdout
    AuditLog.configure($stdout) # 監査ログも stdout へ（1 行 JSON。Cloud Logging がフィールドを解釈）
  else
    log_dir = File.expand_path("log", __dir__)
    # アクセス・監査の記録のため、ディレクトリ・ファイルとも所有者のみに絞る。
    FileUtils.mkdir_p(log_dir, mode: 0o700)
    File.chmod(0o700, log_dir) if File.owned?(log_dir)
    access_log = weekly_log_device(File.join(log_dir, "access.log"))
    AuditLog.configure(weekly_log_device(File.join(log_dir, "audit.log")))
  end
  # CommonLogger のサブクラス。/t/<token> の bearer token を HMAC 短縮 ID に、OAuth callback の
  # クエリ（code/state）を [FILTERED] に置換してから出力する（ログに秘密を残さない）。
  use MaskedAccessLogger, access_log, LOG_TOKEN_ID_KEY
end

# セッションは暗号化 Cookie（AES-CTR＋HMAC）に保持する（サーバ側状態を持たないため、複数インスタンス
# ＝Cloud Run でもそのまま動く）。直列化は serialize_json: true で JSON に固定する（rack-session 2.x の
# 既定は Marshal のため、SESSION_SECRET 漏えい時にデシリアライズ経由のコード実行へ波及させない）。
# key 末尾の .v2 は Marshal→JSON 切替の世代分け（旧形式 Cookie を JSON で読むと例外→500 になるため、
# 名前ごと分離して旧 Cookie を無視させる）。Cookie 属性を強化し、Secure は本番のみ有効化。
# 大きくなり得る同期差分はセッションに載せず、表示・反映時に都度再計算する。
use Rack::Session::Cookie,
    key: "sukesan.session.v2",
    secret: SESSION_SECRET,
    serialize_json: true,
    expire_after: AuthHelpers::ADMIN_SESSION_TTL, # 管理者セッションのサーバ側 TTL と同値（24h）
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
  redirect "#{base_url}#{request.fullpath}", 308 if settings.production? && !request_secure?

  # 仮押さえを実行したブラウザ（holder_key 保持セッション）のみ、Cookie 期限を仮押さえの
  # 操作期間（7 日）へ毎レスポンスで延長する。通常のセッションは既定（24 時間）のまま。
  holder_keys = session[:holder_keys]
  session.options[:expire_after] = TicketStatus::HOLD_TTL_SECONDS if holder_keys.is_a?(Hash) && holder_keys.any?
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
  # URL・登録内容・会議リンク・管理情報を扱う画面はキャッシュさせない。
  if no_store?(request.path_info)
    headers["Cache-Control"] = "no-store"
    headers["Pragma"] = "no-cache"
  end
end

error do
  # 原因調査のため、例外クラスと発生位置だけを stderr（server ログ）へ残す。
  # メッセージ・全文トレースは token 等の秘密を含み得るため出さない。
  e = env["sinatra.error"]
  warn "[error] #{e.class} at #{e.backtrace&.first}" if e
  "エラーが発生しました。しばらくしてから再度お試しください。"
end

not_found do
  # API パスは HTML でなく統一エラーエンベロープ（JSON）で返す。
  # 404 は Sinatra が not_found ハンドラで body を上書きするため、API の 404 はここで一元的に組み立てる。
  if request.path_info.start_with?("/api/")
    content_type :json
    headers["Cache-Control"] = "no-store"
    JSON.generate("error" => { "code" => "not_found", "message" => "見つかりません。" })
  else
    "ページが見つかりません。"
  end
end

# 公開フォーム（スケジュール調整）のスパム対策。IP ごとに 60 秒で 5 回まで。
SCHEDULE_LIMITER = RateLimiter.new(max: 5, window_seconds: 60)

# 空き時間検索（Google API を消費する）の濫用対策。IP ごとに 60 秒で 10 回まで。
SEARCH_LIMITER = RateLimiter.new(max: 10, window_seconds: 60)

# 管理者ログインのブルートフォース対策。IP ごとに「失敗」5 分で 10 回まで（成功は消費しない）。
LOGIN_LIMITER = RateLimiter.new(max: 10, window_seconds: 300)

# 他システム向け API の濫用対策。キーのラベルごとに 60 秒で 60 回まで。
API_LIMITER = RateLimiter.new(max: 60, window_seconds: 60)

# 予約の臨界区間（空き再確認〜カレンダー登録）を直列化し、別トークン同士による同一枠の二重予約を防ぐロック。
# 実体は backend が用意する（file=flock のロックファイル / firestore=プロセス内 Mutex）。
BOOKING_LOCK = TicketStore.booking_lock

# ルートの入力検証で使う上限（DoS・誤入力対策）: 予定名・依頼者名の最大文字数と参加者の最大件数。
# 表示・検証系の定数は使用ロジックの持ち主に置く方針（曜日ラベル・ステータス文言は FormatHelpers、
# URL 長は ScheduleHelpers、同期の最大日数は SyncHelpers、営業日上限は AvailabilitySearch）。
MAX_TEXT_LENGTH = 100
MAX_ATTENDEES = 50

helpers AuthHelpers, OAuthHelpers, FormatHelpers, SettingsParamsHelpers, SyncHelpers, ScheduleHelpers, HoldHelpers,
        ApiHelpers

helpers do
  # 監査ログでチケットを識別する短縮 ID（アクセスログの /t/~xxxxxxxx と同じ導出で相関できる）。
  def audit_ticket_id(token)
    "~#{MaskedAccessLogger.token_short_id(LOG_TOKEN_ID_KEY, token)}"
  end
end

# --- トップ画面（利用案内のみ。調整はワンタイム URL から行う） ---
get "/" do
  @flash = session.delete(:flash)
  erb :home
end

# --- ワンタイム URL の調整画面（発行された token を持つ依頼者だけが利用） ---
get "/t/:token" do
  @token = params[:token].to_s
  @flash = session.delete(:flash)
  @flash_alert = session.delete(:flash_alert) # 入力・状態エラーの警告通知（redirect_with_alert!）
  @form_restore = session.delete(:form_restore) || {} # エラー時に保持した入力値（1 回で消費）
  ticket = TicketStore.find(@token)

  # 仮押さえ中は決定画面（候補一覧・決定・削除）。破壊的操作はホルダー（仮押さえを行った
  # ブラウザ）のみ可能で、URL だけを知る第三者には閲覧のみ許す。
  if TicketStore.held?(ticket)
    @ticket = ticket
    @holder = holder_of?(ticket)
    @holds = ticket["holds"].sort_by { |h| h["slot_start"] }
    @deadline = Time.iso8601(ticket["held_at"]) + TicketStatus::HOLD_TTL_SECONDS
    halt erb(:hold_decision)
  end

  # 無効・期限切れ・使用済み・存在しない token は案内ページを表示する。
  # 410 Gone を返す（404 は not_found ハンドラに横取りされるため使わない）。
  unless TicketStore.active?(ticket)
    forget_holder!(@token) # 終端状態（決定・取りやめ・期限切れ等）の holder キーはセッションから掃除
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
    if !SEARCH_LIMITER.allow?(client_ip)
      status 429
      @flash = "空き時間の検索が多すぎます。しばらく時間をおいてから再度お試しください。"
    elsif (google_access = google_token).nil?
      # refresh 失敗など連携トークンが使えない場合は 500 にせず案内を返す（復旧は管理者の再連携で行う）。
      @flash = "現在カレンダーとの連携に問題があるため検索できません。管理者にお問い合わせください。"
    else
      result = availability_search(@settings, google_access).search(
        start_date: @start_date, end_date: @end_date, duration_minutes: @duration.to_i
      )
      @searched = result.searched
      @capped = result.capped
      @results = result.days
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

  # 連携トークンが使えない（refresh 失敗など）場合は、チケットを消費する前に案内を返す。
  google_access = google_token
  halt 502, "現在カレンダーとの連携に問題があるため登録できません。管理者にお問い合わせください。" if google_access.nil?

  # 予約の中核トランザクション（空き再確認→token 消費→Google 登録→失敗時ロールバック）は
  # BookingService に委譲する。HTTP ステータスへの写像だけルート側で行う。
  result = BookingService.new(
    lock: BOOKING_LOCK,
    availability: availability_search(SettingsStore.load, google_access),
    calendar_client: GoogleCalendarClient.new(google_access),
    event_id_key: EVENT_ID_KEY
  ).call(token: token, event: event, ticket_attrs: ticket_attrs,
         attendees: event_attendees, request_meet: request_meet)

  case result.status
  when :slot_taken
    halt 422, "選択した時間帯は予約できません。お手数ですが再度空き時間をチェックしてください。"
  when :ticket_used
    halt 409, "この URL は既に使用されています。"
  when :api_failure
    AuditLog.record(:booking_failed, ip: client_ip, target: audit_ticket_id(token))
    halt 502, "予定の登録に失敗しました。お手数ですが、もう一度お試しください。"
  end

  AuditLog.record(:booking_created, ip: client_ip, target: audit_ticket_id(token))
  # 会議情報は登録直後の本人セッションでだけ完了画面に表示する（チケットには残さない）。
  session[:completion] = { "token" => token, "meet_link" => result.meet_link, "video_url" => video_url }
  session[:flash] = "#{requester} さんの「#{title}」を #{format_dt(event.starts_at)} に登録しました。"
  redirect "/t/#{token}"
end

# --- 複数カレンダー仮押さえ（ワンタイム URL からのみ） ---
# 指定期間の候補から最大 MAX_HOLDS 件を [仮ブロック] としてカレンダーに作成し、チケットを held にする。
post "/hold" do
  halt 429, "リクエストが多すぎます。しばらく時間をおいてからお試しください。" unless SCHEDULE_LIMITER.allow?(client_ip)

  token = params[:token].to_s
  ticket = TicketStore.find(token)
  # 入力・状態のエラーはエラーページでなく、元画面上部の警告通知（flash_alert）で伝える。
  # 入力値はエラー後の画面で復元する（redirect_with_alert! が一時保存。文字数はコピー上限で抑える）。
  @form_restore = {
    "requester" => params[:requester].to_s[0, 200], "title" => params[:title].to_s[0, 200],
    "slots" => Array(params[:slots]).map(&:to_s)
  }
  redirect_with_alert!(token, "この URL は無効か、期限切れです。管理者に新しい URL の発行を依頼してください。") unless TicketStore.active?(ticket)
  redirect_with_alert!(token, "Google の連携が必要です。管理者にお問い合わせください。") unless google_connected?

  title = params[:title].to_s.strip
  requester = params[:requester].to_s.strip
  redirect_with_alert!(token, "依頼者名・予定名を入力してください。") if title.empty? || requester.empty?
  too_long = title.length > MAX_TEXT_LENGTH || requester.length > MAX_TEXT_LENGTH
  redirect_with_alert!(token, "予定名・依頼者名が長すぎます（各 #{MAX_TEXT_LENGTH} 文字以内）。") if too_long

  slots = parse_hold_slots(params[:slots])
  redirect_with_alert!(token, "仮押さえする時間帯を選択してください。") if slots.empty?
  if slots.size > HoldService::MAX_HOLDS
    redirect_with_alert!(token, "仮押さえは最大 #{HoldService::MAX_HOLDS} 件までです。選び直してください。")
  end
  redirect_with_alert!(token, "時間帯の形式が正しくありません。") if slots.any? { |starts_at, _| starts_at.nil? }
  redirect_with_alert!(token, "選択した時間帯が重複しています。重ならないように選び直してください。") if overlapping_slots?(slots)
  redirect_with_alert!(token, "過去の時間帯は仮押さえできません。再度空き時間をチェックしてください。") if slots.any? do |s, _|
    AvailabilitySearch.too_soon?(s)
  end

  google_access = google_token
  redirect_with_alert!(token, "現在カレンダーとの連携に問題があるため仮押さえできません。管理者にお問い合わせください。") if google_access.nil?

  # ホルダーキー: 決定・削除の操作をこのブラウザに限定するための第二要素（チケットとセッションの両方へ保存）。
  holder_key = SecureRandom.urlsafe_base64(32)
  result = hold_service(google_access).hold(token: token, requester: requester, title: title,
                                            slots: slots, holder_key: holder_key)

  case result.status
  when :slot_taken
    redirect_with_alert!(token, "選択した時間帯は予約できなくなりました。再度空き時間をチェックしてください。")
  when :ticket_used
    redirect_with_alert!(token, "この URL は既に使用されています。")
  when :api_failure
    redirect_with_alert!(token, "仮押さえに失敗しました。お手数ですが、もう一度お試しください。")
  end

  remember_holder!(token, holder_key)
  AuditLog.record(:hold_created, ip: client_ip, target: "#{audit_ticket_id(token)} count=#{slots.size}")
  session[:flash] = "#{slots.size} 件の日程を仮押さえしました。この画面から 7 日以内に 1 件へ決定してください。"
  redirect "/t/#{token}"
end

# 仮押さえから 1 件に決定する（ホルダーのみ）。任意項目（参加者・ビデオ URL・Meet）はここで指定する。
post "/hold/confirm" do
  halt 429, "リクエストが多すぎます。しばらく時間をおいてからお試しください。" unless SCHEDULE_LIMITER.allow?(client_ip)

  token = params[:token].to_s
  ticket = TicketStore.find(token)
  redirect_with_alert!(token, "この操作は完了済みか、期限切れです。") unless TicketStore.held?(ticket)
  halt 403, "この操作は仮押さえを行ったブラウザからのみ行えます。" unless holder_of?(ticket)

  # エラー時に決定画面の入力値（任意項目・選択スロット）を復元する。
  @form_restore = {
    "slot" => params[:slot].to_s, "attendees" => params[:attendees].to_s[0, 2000],
    "video_url" => params[:video_url].to_s[0, ScheduleHelpers::MAX_URL_LENGTH],
    "request_meet" => params[:request_meet].to_s
  }

  slot_start = params[:slot].to_s
  redirect_with_alert!(token, "決定する日程を選択してください。") if ticket["holds"].none? { |h| h["slot_start"] == slot_start }

  attendees = parse_attendees(params[:attendees])
  video_url = params[:video_url].to_s.strip
  request_meet = params[:request_meet].to_s == "1"
  redirect_with_alert!(token, "参加者は最大 #{MAX_ATTENDEES} 件までです。") if attendees.size > MAX_ATTENDEES
  redirect_with_alert!(token, "参加者メールアドレスの形式が正しくありません。") unless attendees.all? { |email| valid_email?(email) }
  unless video_url.empty? || valid_http_url?(video_url)
    redirect_with_alert!(token,
                         "ビデオ会議 URL の形式が正しくありません（http/https の URL）。")
  end
  redirect_with_alert!(token, "ビデオ会議 URL の指定と Google Meet の発行は同時に指定できません。") if request_meet && !video_url.empty?

  google_access = google_token
  redirect_with_alert!(token, "現在カレンダーとの連携に問題があるため操作できません。管理者にお問い合わせください。") if google_access.nil?

  event_attendees = ([google_admin_email.to_s] + attendees).reject(&:empty?).uniq(&:downcase)
  result = hold_service(google_access).confirm(token: token, slot_start: slot_start,
                                               attendees: event_attendees, video_url: video_url,
                                               request_meet: request_meet)
  redirect_with_alert!(token, "この操作は完了済みか、期限切れです。画面を再読み込みしてください。") if result.status == :not_held

  forget_holder!(token)
  AuditLog.record(:hold_confirmed, ip: client_ip, target: audit_ticket_id(token))
  # 会議情報は決定直後の本人セッションでだけ完了画面に表示する（チケットには残さない）。
  session[:completion] = { "token" => token, "meet_link" => result.meet_link, "video_url" => video_url }
  session[:flash] = "「#{ticket['title']}」を #{format_iso(slot_start)} に決定しました。#{hold_result_notes(result)}".strip
  redirect "/t/#{token}"
end

# 仮押さえから 1 件を削除する（ホルダーのみ）。最後の 1 件を削除するとこの URL は終了する。
post "/hold/delete" do
  halt 429, "リクエストが多すぎます。しばらく時間をおいてからお試しください。" unless SCHEDULE_LIMITER.allow?(client_ip)

  token = params[:token].to_s
  ticket = TicketStore.find(token)
  redirect_with_alert!(token, "この操作は完了済みか、期限切れです。") unless TicketStore.held?(ticket)
  halt 403, "この操作は仮押さえを行ったブラウザからのみ行えます。" unless holder_of?(ticket)

  google_access = google_token
  redirect_with_alert!(token, "現在カレンダーとの連携に問題があるため操作できません。管理者にお問い合わせください。") if google_access.nil?

  result = hold_service(google_access).remove(token: token, slot_start: params[:slot].to_s)
  redirect_with_alert!(token, "該当の仮押さえが見つかりません。画面を再読み込みしてください。") if result.status == :not_held

  AuditLog.record(:hold_deleted, ip: client_ip, target: audit_ticket_id(token))
  if TicketStore.held?(TicketStore.find(token))
    session[:flash] = "仮押さえを 1 件削除しました。#{hold_result_notes(result)}".strip
  else
    forget_holder!(token) # 最後の 1 件を削除＝終了（cancelled）
    session[:flash] = "すべての仮押さえを削除したため、この URL は終了しました。#{hold_result_notes(result)}".strip
  end
  redirect "/t/#{token}"
end

# 仮押さえをすべて取りやめて終了する（ホルダーのみ）。
post "/hold/cancel" do
  halt 429, "リクエストが多すぎます。しばらく時間をおいてからお試しください。" unless SCHEDULE_LIMITER.allow?(client_ip)

  token = params[:token].to_s
  ticket = TicketStore.find(token)
  redirect_with_alert!(token, "この操作は完了済みか、期限切れです。") unless TicketStore.held?(ticket)
  halt 403, "この操作は仮押さえを行ったブラウザからのみ行えます。" unless holder_of?(ticket)

  google_access = google_token
  redirect_with_alert!(token, "現在カレンダーとの連携に問題があるため操作できません。管理者にお問い合わせください。") if google_access.nil?

  result = hold_service(google_access).cancel(token: token)
  redirect_with_alert!(token, "この操作は完了済みか、期限切れです。画面を再読み込みしてください。") if result.status == :not_held

  forget_holder!(token)
  AuditLog.record(:hold_cancelled, ip: client_ip, target: audit_ticket_id(token))
  session[:flash] = "仮押さえをすべて取りやめました。#{hold_result_notes(result)}".strip
  redirect "/t/#{token}"
end

# --- 管理者ログイン ---
post "/settings/login" do
  # 失敗回数だけを数える。bcrypt 計算の前に弾くことで CPU 消耗型の総当たりも防ぐ。
  halt 429, "ログイン試行が多すぎます。しばらく時間をおいてからお試しください。" if LOGIN_LIMITER.exceeded?(client_ip)

  if admin_password_valid?(params[:password].to_s)
    session.options[:renew] = true # セッション固定対策: ログイン時に session id を再生成
    session[:admin] = true
    session[:admin_at] = Time.now.to_i # サーバ側 TTL 検証用のログイン時刻（AuthHelpers#admin?）
    AuditLog.record(:login_success, ip: client_ip)
  else
    LOGIN_LIMITER.record(client_ip) # 失敗時のみ記録（成功ログインは制限を消費しない）
    AuditLog.record(:login_failure, ip: client_ip)
    session[:flash] = "パスワードが正しくありません。"
  end
  redirect "/admin"
end

post "/settings/logout" do
  session.clear
  session.options[:drop] = true # ログアウト時はセッションを破棄する
  redirect "/admin"
end

# --- 管理者トップ（各ツールへの導線ハブ。認証していなければログイン画面を表示） ---
get "/admin" do
  require_admin_page!
  erb :admin
end

# --- Google カレンダー調整ツール（ワンタイム URL の発行・一覧。認証していなければログイン画面を表示） ---
# 一覧は直近 30 日分（TicketStore.all 側で絞り込み済み）をページングして表示する。
PER_PAGE_OPTIONS = [10, 20, 50, 100].freeze
DEFAULT_PER_PAGE = 10

get "/tickets" do
  require_admin_page!
  tickets = TicketStore.all
  # 表示件数はホワイトリスト照合（不正値・未指定は既定 10）。ページは 1 以上に丸め、範囲外は端へクランプ。
  @per = PER_PAGE_OPTIONS.include?(params[:per].to_i) ? params[:per].to_i : DEFAULT_PER_PAGE
  @total = tickets.size
  @total_pages = [(@total.to_f / @per).ceil, 1].max
  @page = params[:page].to_i.clamp(1, @total_pages)
  @tickets = tickets.slice((@page - 1) * @per, @per) || []
  erb :tickets
end

# --- 設定（管理者専用：認証していなければログイン画面を表示） ---
get "/settings" do
  require_admin_page!
  @settings = SettingsStore.load
  erb :settings
end

# 1回限りのスケジュール調整 URL を発行する（管理者専用）。
post "/tickets" do
  require_admin!
  token = TicketStore.create
  AuditLog.record(:ticket_create, ip: client_ip, target: audit_ticket_id(token))
  session[:flash] = "ワンタイム URL を発行しました。"
  redirect "/tickets"
end

# 発行済みワンタイム URL を手動で無効化する（管理者専用）。
# 仮押さえ中だったチケットは、残っている [仮ブロック] イベントも削除する（URL 漏えい・放置時の kill switch）。
post "/tickets/:token/revoke" do
  require_admin!
  previous = TicketStore.revoke(params[:token].to_s)
  failed = previous.is_a?(Hash) ? delete_hold_events(Array(previous["holds"])) : 0
  AuditLog.record(:ticket_revoke, ip: client_ip, target: audit_ticket_id(params[:token].to_s))
  session[:flash] = "ワンタイム URL を無効化しました。"
  session[:flash] += " ※#{failed} 件の仮押さえイベントを削除できませんでした。" if failed.positive?
  redirect "/tickets"
end

post "/settings" do
  require_admin!
  values = settings_params
  if settings_valid?(values)
    SettingsStore.save(values)
    AuditLog.record(:settings_update, ip: client_ip)
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
  AuditLog.record(:oauth_disconnect, ip: client_ip, target: "google")
  session[:flash] = "Google 連携を解除しました。"
  redirect "/settings"
end

# --- Outlook 同期（管理者専用） ---
get "/sync" do
  require_admin_page!
  @settings = SettingsStore.load
  # チェック直後の表示は 1 回だけ（POST /check で立てたフラグを消費）。更新・再表示時はフラグが無いので
  # 前回の取得範囲を破棄し、未チェック状態に戻す（古い結果を残さない）。
  clear_sync_window unless session.delete(:sync_show)
  @test_mode = sync_test_mode?
  window = current_sync_window
  @checked = !window.nil?
  # 差分はキャッシュせず、取得範囲から都度再計算する（常に最新）。
  @events = if window && google_connected? && microsoft_connected?
              compute_outlook_only(window)
            else
              []
            end
  # nil はトークンが使えない（refresh 失敗など）。「該当なし」と誤認させず、再連携を促す。
  if @events.nil?
    @checked = false
    @events = []
    @flash ||= "カレンダー連携の更新に失敗しました。お手数ですが、連携を解除して再度連携してください。"
  end
  erb :sync
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
  AuditLog.record(:oauth_connect, ip: client_ip, target: "google")
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
  AuditLog.record(:oauth_connect, ip: client_ip, target: "microsoft")
  redirect "/sync"
end

post "/disconnect" do
  require_admin!
  TokenStore.clear(:microsoft)
  clear_sync_window
  AuditLog.record(:oauth_disconnect, ip: client_ip, target: "microsoft")
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

  # 差分はここでは取得せず、取得範囲とテストモードだけ保存する（表示時に再計算）。
  store_sync_window(window, test_mode: params[:test_mode] == "1")
  session[:sync_show] = true # チェック直後の表示は 1 回だけ（更新・再表示では結果を残さない）
  redirect "/sync"
end

# --- 同期（選択したイベントのみ Google へ反映。管理者専用） ---
post "/sync" do
  require_admin!
  halt 400, "Google と Outlook の両方の連携が必要です" unless google_connected? && microsoft_connected?
  # テストモードでチェックした直後は反映しない（誤適用防止）。
  if sync_test_mode?
    session[:flash] = "テストモードのため反映しません。反映するにはテストモードを外して再チェックしてください。"
    redirect "/sync"
  end

  window = current_sync_window
  unless window
    session[:flash] = "取得範囲が見つかりません。もう一度チェックしてください。"
    redirect "/sync"
  end

  # 反映直前に差分を取り直し、選択のうち「今も Outlook 側にのみ存在する」ものだけ登録する。
  # 既に Google にあるもの（前回反映済み含む）は差分から外れるため、二重作成にならない。
  # 選択は一意な external_id で照合する（同一件名・同一時刻の重複イベントを取り違えないため）。
  selected = Array(params[:selected])
  google_access = google_token
  events = google_access && compute_outlook_only(window)
  # nil はトークンが使えない（refresh 失敗など）。反映せず再連携を促す。
  if events.nil?
    session[:flash] = "カレンダー連携の更新に失敗しました。お手数ですが、連携を解除して再度連携してください。"
    redirect "/sync"
  end

  # 反映は 1 件ずつ失敗を切り分け、部分失敗はエラーページでなく件数付きの通知で伝える
  # （登録済み分は次回チェックの差分から自然に消えるため、再チェック→残りの再選択で復旧できる）。
  client = GoogleCalendarClient.new(google_access)
  targets = events.select { |event| selected.include?(event.external_id) }
  failed = targets.count do |event|
    client.create_event(event)
    false
  rescue StandardError => e
    warn "[sync] イベントの同期失敗: #{e.class}"
    true
  end
  session[:flash] =
    if failed.zero?
      "選択したイベントを Google に同期しました。"
    else
      "#{targets.size - failed} 件を同期しました（#{failed} 件は失敗しました。もう一度チェックしてお試しください）。"
    end
  redirect "/sync"
end

# --- 他システム向け API（/api/v1/…。同一マシン上の別システムから利用する JSON API） ---
# 認証・認可（deny-by-default）は before フィルタでまとめて行い、各ルートは業務ロジックに徹する。
# セッションは使わない・変更しない（API はステートレス）。
before "/api/*" do
  # CALENDAR_API_KEYS 未設定なら API 自体が存在しない扱い（本番 Cloud Run に影響させないための仕様）。
  # 404 は not_found ハンドラが body を組み立てる（API パスなら JSON エンベロープ）。
  halt 404 if CALENDAR_API_KEYS.nil?

  # loopback 限定。偽装できない REMOTE_ADDR で判定する（APP_TRUST_PROXY=true でも X-Forwarded-For は見ない）。
  api_error!(403, "forbidden", "この API はローカルホストからのみ利用できます。") unless loopback?

  # Authorization: Bearer <キー> のみ。一致したキーのラベルを以後の識別子（レート制限・監査）に使う。
  @api_label = authenticate_api_key(CALENDAR_API_KEYS)
  if @api_label.nil?
    AuditLog.record(:api_auth_failed, ip: remote_addr)
    api_error!(401, "unauthorized", "認証に失敗しました。")
  end

  # レート制限はキーのラベル単位（IP ではなくキーで数える）。
  api_error!(429, "rate_limited", "リクエストが多すぎます。しばらく時間をおいてください。") unless API_LIMITER.allow?(@api_label)
end

# 指定日（既定は今日）の Google カレンダーのイベント一覧を返す。
get "/api/v1/calendars/google/events" do
  # date は任意。省略時はアプリのタイムゾーンでの「今日」。不正な形式は 400。
  date_param = params[:date].to_s
  date = if date_param.empty?
           Date.today
         else
           begin
             Date.iso8601(date_param)
           rescue ArgumentError
             api_error!(400, "invalid_date", "date は YYYY-MM-DD 形式で指定してください。")
           end
         end

  # 対象期間はその日の 0:00 から翌日 0:00（ローカルタイム）。
  time_min = Time.local(date.year, date.month, date.day)
  time_max = time_min + (24 * 60 * 60)

  # 保存済みトークンを使う（refresh 失敗・未連携は nil）。使えない場合は未連携として 503。
  google_access = google_token
  api_error!(503, "provider_not_connected", "Google カレンダーが連携されていません。") if google_access.nil?

  # Google API 呼び出しの失敗は詳細を出さず upstream_error に丸める（トークン等を漏らさない）。
  begin
    events = GoogleCalendarClient.new(google_access).list_events(time_min: time_min, time_max: time_max)
  rescue StandardError => e
    warn "[api] Google イベント取得失敗: #{e.class}"
    api_error!(502, "upstream_error", "カレンダーの取得に失敗しました。")
  end

  api_json(
    "date" => date.strftime("%F"),
    "events" => events.map { |event| api_event(event) }
  )
end
