# frozen_string_literal: true

require "digest"

# 同一マシン上の他システム向け JSON API（/api/v1/…）の認証・認可・応答ヘルパ。
#
# 方針（deny-by-default）:
# - API キーは管理画面（/settings）で発行し、SettingsStore に SHA-256 ダイジェストのみ保存する
#   （生のキーは発行直後に一度だけ表示し、永続化しない）。発行済みキーが 1 つもなければ /api/ 配下は 404。
# - 接続元は loopback（127.0.0.1 / ::1）限定。判定は偽装できない REMOTE_ADDR を使う。
# - 認証は Authorization: Bearer <キー> のみ。照合は定数時間比較（ダイジェスト同士＝固定長で比較）。
# - キーは read / write のスコープを持ち、書き込み系は write を要求する（write は read を包含する）。
module ApiHelpers
  # 発行フォームのラベル（システム名）の最大文字数と、登録できるキーの最大件数（DoS・誤入力対策）。
  MAX_API_KEY_LABEL_LENGTH = 50
  MAX_API_KEYS = 20

  # API キーのスコープ。read は参照のみ、write は参照＋書き込み（予定の作成・削除など）。
  API_KEY_SCOPES = %w[read write].freeze
  DEFAULT_API_KEY_SCOPE = "read"

  # loopback とみなす接続元アドレス（REMOTE_ADDR）。IPv4/IPv6 のループバックのみ許可する。
  LOOPBACK_ADDRS = ["127.0.0.1", "::1"].freeze

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

  # Event 構造体を API レスポンス用のハッシュに変換する。
  # 時刻は ISO8601（ローカルタイムのオフセット付き）で返す。
  def api_event(event)
    {
      "id" => event.external_id,
      "title" => event.title,
      "starts_at" => api_time(event.starts_at),
      "ends_at" => api_time(event.ends_at),
      "location" => event.location,
      "all_day" => event.all_day
    }
  end

  def api_time(time)
    time&.getlocal&.iso8601
  end
end
