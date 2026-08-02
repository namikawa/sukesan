# frozen_string_literal: true

require "date"
require "digest"

# 同一マシン上の他システム向け JSON API（/api/v1/…）の認証・認可・応答ヘルパ。
#
# 方針（deny-by-default）:
# - API キーは管理画面（/settings）で発行し、SettingsStore に SHA-256 ダイジェストのみ保存する
#   （生のキーは発行直後に一度だけ表示し、永続化しない）。発行済みキーが 1 つもなければ /api/ 配下は 404。
# - 接続元は loopback（127.0.0.1 / ::1）限定。判定は偽装できない REMOTE_ADDR を使う。
# - 認証は Authorization: Bearer <キー> のみ。照合は定数時間比較（ダイジェスト同士＝固定長で比較）。
# - キーは read / write のスコープを持ち、書き込み系は write を要求する（write は read を包含する）。
#
# レスポンス（ドメインオブジェクト → JSON 用 Hash）の整形は ApiSerializers に分離している。
module ApiHelpers
  # 発行フォームのラベル（システム名）の最大文字数と、登録できるキーの最大件数（DoS・誤入力対策）。
  MAX_API_KEY_LABEL_LENGTH = 50
  MAX_API_KEYS = 20

  # API キーのスコープ。read は参照のみ、write は参照＋書き込み（予定の作成・削除など）。
  API_KEY_SCOPES = %w[read write].freeze
  DEFAULT_API_KEY_SCOPE = "read"

  # loopback とみなす接続元アドレス（REMOTE_ADDR）。IPv4/IPv6 のループバックのみ許可する。
  LOOPBACK_ADDRS = ["127.0.0.1", "::1"].freeze

  # チケット一覧の status クエリで指定できる値（TicketStore.status の派生値）。
  # 破損・改ざんを表す "invalid" は絞り込みの対象にしない。
  API_TICKET_STATUSES = %w[active held used revoked cancelled expired].freeze

  # 書き込み系リクエストボディの上限（バイト）。想定最大の入力（attendees 50 件等）にも十分な余裕を
  # 持たせつつ、誤送信・暴走による巨大ボディの読み込みを防ぐ（DoS・メモリ消費対策）。
  MAX_JSON_BODY_BYTES = 64 * 1024

  # スコープを許可値に丸める。許可外・未指定・scope 未保存の既存キーはすべて read 扱い（fail-closed）。
  # 発行フォームの入力検証と、保存済みキーの読み出しの両方で使う。
  def normalize_api_key_scope(value)
    scope = value.to_s
    API_KEY_SCOPES.include?(scope) ? scope : DEFAULT_API_KEY_SCOPE
  end

  # 保存済みの発行キー一覧（{ ラベル => { "digest" =>…, "created_at" =>…, "scope" =>… } }）。未発行なら空ハッシュ。
  def stored_api_keys
    keys = SettingsStore.load["api_keys"]
    keys.is_a?(Hash) ? keys : {}
  end

  # 発行フォームのラベル検証。問題があればエラーメッセージ、なければ nil を返す。
  def api_key_label_error(label, keys)
    return "システム名を入力してください。" if label.empty?
    return "システム名が長すぎます（#{MAX_API_KEY_LABEL_LENGTH} 文字以内）。" if label.length > MAX_API_KEY_LABEL_LENGTH
    return "同じシステム名のキーが既に発行されています。別の名前を指定してください。" if keys.key?(label)
    return "API キーの登録数が上限（#{MAX_API_KEYS} 件）に達しています。不要なキーを削除してください。" if keys.size >= MAX_API_KEYS

    nil
  end

  # 接続元が loopback か。X-Forwarded-For に影響されない REMOTE_ADDR で判定する
  # （APP_TRUST_PROXY=true でもスプーフィングで loopback を偽装できないようにする）。
  def loopback?
    LOOPBACK_ADDRS.include?(remote_addr)
  end

  def remote_addr
    request.env["REMOTE_ADDR"].to_s
  end

  # Authorization: Bearer <キー> を検証し、一致したキーの [ラベル, スコープ] を返す（不一致・ヘッダ無しは nil）。
  # 提示されたキーを SHA-256 hex 化し、保存済みダイジェストと定数時間比較する
  # （ダイジェスト同士＝固定長の比較で、キー本体の長さも漏らさない）。
  def authenticate_api_key(keys)
    header = request.env["HTTP_AUTHORIZATION"].to_s
    presented = header[/\ABearer\s+(.+)\z/, 1]
    return nil if presented.nil? || presented.empty?

    presented_digest = Digest::SHA256.hexdigest(presented)
    label, info = keys.find { |_key_label, entry| Rack::Utils.secure_compare(presented_digest, entry["digest"].to_s) }
    return nil if label.nil?

    [label, normalize_api_key_scope(info["scope"])]
  end

  # 書き込み系エンドポイントで write スコープを要求する（before フィルタで認証済みの @api_scope を見る）。
  # read キー（scope 未保存の既存キーを含む）は 403 insufficient_scope。
  # 試行を可視化するため監査ログに残す（対象はキーのラベルのみ。秘密・PII は記録しない）。
  def require_write_scope!
    return if @api_scope == "write"

    AuditLog.record(:api_scope_denied, ip: remote_addr, target: @api_label)
    api_error!(403, "insufficient_scope", "この操作には write 権限の API キーが必要です。")
  end

  # 統一エラーエンベロープ（{"error": {"code", "message"}}）で JSON 応答を返して中断する。
  # code は呼び出し側が使い分ける。no-store は after フィルタ（AuthHelpers#no_store?）が一元的に付与する。
  # 404 は Sinatra が not_found ハンドラで body を上書きするため、ここでは扱わない（404 は halt 404 + not_found 側）。
  def api_error!(status_code, code, message)
    content_type :json
    halt status_code, JSON.generate("error" => { "code" => code, "message" => message })
  end

  # 成功時の JSON 応答（Content-Type を付ける）。no-store は after フィルタ（AuthHelpers#no_store?）が一元的に付与する。
  def api_json(payload)
    content_type :json
    JSON.generate(payload)
  end

  # 書き込み系（POST）のリクエストボディ（JSON オブジェクト）を Hash として読む。
  # 空ボディは {}（＝すべて既定値）として扱い、JSON として壊れている・トップレベルがオブジェクトでない
  # 場合は 400 invalid_params で中断する。フォーム形式（application/x-www-form-urlencoded）で
  # 送られた場合も JSON として解釈できず 400 になる（この API の入力は JSON のみ）。
  def api_json_body!
    raw = read_api_body!
    return {} if raw.strip.empty?

    parsed = JSON.parse(raw)
    return parsed if parsed.is_a?(Hash)

    api_error!(400, "invalid_params", "リクエストボディは JSON オブジェクトで指定してください。")
  rescue JSON::ParserError
    api_error!(400, "invalid_params", "リクエストボディを JSON として解釈できません。")
  end

  # リクエストボディを上限までしか読まずに取り出す。超過は 400 invalid_params で中断する
  # （上限 +1 バイトまでしか読まないため、巨大ボディでも全体をメモリへ載せない）。
  def read_api_body!
    request.body.rewind # フォーム系の Content-Type では params 解決で Rack が読み進めているため先頭へ戻す
    raw = request.body.read(MAX_JSON_BODY_BYTES + 1).to_s
    return raw if raw.bytesize <= MAX_JSON_BODY_BYTES

    api_error!(400, "invalid_params", "リクエストボディが大きすぎます（#{MAX_JSON_BODY_BYTES / 1024}KB 以内）。")
  end

  # 必須の日付クエリ（YYYY-MM-DD）を Date へ変換する。欠落・不正形式は 400 invalid_params で中断する。
  def api_date_param!(name)
    Date.iso8601(params[name].to_s)
  rescue ArgumentError
    api_error!(400, "invalid_params", "#{name} は YYYY-MM-DD 形式で指定してください（必須）。")
  end

  # 必須の所要時間クエリ（分）を Integer へ変換する。許可するのは正かつ刻み（15 分）の倍数のみ
  # （AvailabilitySearch の受け入れ条件と揃える）。不正は 400 invalid_params で中断する。
  def api_duration_param!(name)
    step = AvailabilitySearch::DURATION_STEP_MINUTES
    minutes = Integer(params[name].to_s, 10, exception: false) # 10 進数のみ（"030" を 8 進数と解釈させない）
    return minutes if minutes&.positive? && (minutes % step).zero?

    api_error!(400, "invalid_params", "#{name} は #{step} 分単位の正の整数で指定してください（必須）。")
  end

  # チケット一覧の status クエリ（任意）。未指定は nil（絞り込みなし）、許可外は 400 invalid_params。
  def api_ticket_status_param!(name)
    value = params[name].to_s
    return nil if value.empty?
    return value if API_TICKET_STATUSES.include?(value)

    api_error!(400, "invalid_params", "#{name} は #{API_TICKET_STATUSES.join(' / ')} のいずれかで指定してください。")
  end
end
