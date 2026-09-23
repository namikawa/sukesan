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
require_relative "lib/event_format"
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
require_relative "lib/masked_access_logger"
require_relative "lib/audit_log"
require_relative "lib/slack_notifier"

require_relative "helpers/auth_helpers"
require_relative "helpers/oauth_helpers"
require_relative "helpers/format_helpers"
require_relative "helpers/pagination_helpers"
require_relative "helpers/settings_params_helpers"
require_relative "helpers/sync_helpers"
require_relative "helpers/schedule_helpers"
require_relative "helpers/hold_helpers"
require_relative "helpers/notify_helpers"
require_relative "helpers/api_helpers"
require_relative "helpers/api_write_params"
require_relative "helpers/api_serializers"

# タイムゾーンを固定する（特定地域での運用前提。グローバル運用は想定しない）。
# APP_TIMEZONE（既定 Asia/Tokyo）をプロセスの TZ に適用し、サーバ OS の設定に依存させない。
# 以降の Time.now / Time.local / getlocal はすべてこのタイムゾーンで解釈・表示される。
APP_TIMEZONE = ENV.fetch("APP_TIMEZONE", "Asia/Tokyo")
ENV["TZ"] = APP_TIMEZONE

set :bind, "0.0.0.0"
set :port, ENV.fetch("PORT", "3000").to_i

# ERB 出力を既定で HTML エスケープする（XSS 対策）。生 HTML を通す箇所は <%== %> を使う。
set :erb, escape_html: true

# 例外にはトークン等の秘密が含まれ得るため、全環境で Sinatra の詳細表示と例外ダンプを抑止する。
set :show_exceptions, false
set :dump_errors, false

configure :production do
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

  # ゲスト操作を管理者の Slack へ通知する（任意）。SLACK_WEBHOOK_URL 未設定・空なら configure せず
  # 通知無効のまま（deny-by-default）。テスト環境では configure しないため既定 no-op。
  # SLACK_MENTION で通知本文の先頭に付けるメンションを指定できる（channel / here / メンバー ID。
  # 未設定・不正値ならメンションなし）。
  SlackNotifier.configure(ENV.fetch("SLACK_WEBHOOK_URL", nil), mention: ENV.fetch("SLACK_MENTION", nil))
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
# 例外は /api/ 配下のみ: 資格情報は Authorization: Bearer ヘッダだけで、ブラウザが自動送信する
# セッション Cookie を認証に使わないため CSRF が成立しない（トークンを持てない他システムからの POST を通す）。
# 除外は rack-protection 公式の allow_if フックで API パスの前方一致に限定し、画面のフォームは従来どおり全て検証する。
use Rack::Protection::AuthenticityToken,
    allow_if: ->(env) { env["PATH_INFO"].to_s.start_with?("/api/") }

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
  # no-store は after フィルタ（AuthHelpers#no_store?）が一元的に付与する。
  if request.path_info.start_with?("/api/")
    content_type :json
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

# 他システム向け API のうち書き込み系（予定の作成・削除など）の濫用対策。キーのラベルごとに 60 秒で 10 回まで。
API_WRITE_LIMITER = RateLimiter.new(max: 10, window_seconds: 60)

# 予約の臨界区間（空き再確認〜カレンダー登録）を直列化し、別トークン同士による同一枠の二重予約を防ぐロック。
# 実体は backend が用意する（file=flock のロックファイル / firestore=プロセス内 Mutex）。
BOOKING_LOCK = TicketStore.booking_lock

# ルートの入力検証で使う上限（DoS・誤入力対策）: 予定名・依頼者名の最大文字数。
# 表示・検証系の定数は使用ロジックの持ち主に置く方針（曜日ラベル・ステータス文言は FormatHelpers、
# URL 長・参加者上限は ScheduleHelpers、同期の最大日数は SyncHelpers、営業日上限は AvailabilitySearch）。
MAX_TEXT_LENGTH = 100

# 一覧のページング（管理画面 GET /tickets と API GET /api/v1/tickets で共有するため app.rb に置く）。
# 一覧は直近 30 日分（TicketStore.all 側で絞り込み済み）をページングして表示する。
PER_PAGE_OPTIONS = [10, 20, 50, 100].freeze
DEFAULT_PER_PAGE = 10

helpers AuthHelpers, OAuthHelpers, FormatHelpers, PaginationHelpers, SettingsParamsHelpers, SyncHelpers,
        ScheduleHelpers, HoldHelpers, NotifyHelpers, ApiHelpers, ApiWriteParams, ApiSerializers

# app.rb 固有の鍵定数（LOG_TOKEN_ID_KEY）に依存するヘルパのみをここに置く。
# 表示整形の共通ヘルパは helpers/*.rb（例: Slack 通知の slack_slot_label は FormatHelpers）に置く。
helpers do
  # 監査ログでチケットを識別する短縮 ID（アクセスログの /t/~xxxxxxxx と同じ導出で相関できる）。
  def audit_ticket_id(token)
    "~#{MaskedAccessLogger.token_short_id(LOG_TOKEN_ID_KEY, token)}"
  end

  # 短縮 ID（API のチケット識別子）から実チケットを引く。ID から生 token は復元できないため、
  # 一覧と同じ直近 30 日分を走査して照合する（件数が限られるため線形で十分）。
  def find_ticket_by_api_id(id)
    TicketStore.all.find { |ticket| audit_ticket_id(ticket["token"]) == id }
  end

  # Idempotency-Key から決定的に導く Google イベント ID（キー未指定なら nil＝token 由来の既定を使う）。
  # 同じキーでのリトライは同じ ID になり、リプレイ検索と登録の間で競合しても Google の 409 で吸収される。
  # token 由来の ID と衝突しないよう、用途を示す prefix を HMAC の入力に含める。
  def idempotency_event_id(key)
    key && BookingService.event_id(EVENT_ID_KEY, "idem:#{key}")
  end
end

# ルート定義は関心ごとにファイルを分ける。Sinatra クラシックの get/post/before は
# トップレベルから Sinatra::Application へ委譲されるため、読み込みの順序がそのまま
# ルートのマッチ順・before フィルタの実行順になる（上の共通フィルタを先に置くため末尾で読み込む）。
require_relative "routes/guest"
require_relative "routes/admin"
require_relative "routes/api_v1"
