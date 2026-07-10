# frozen_string_literal: true

require "digest"

# 同一マシン上の他システム向け JSON API（/api/v1/…）の認証・認可・応答ヘルパ。
#
# 方針（deny-by-default）:
# - CALENDAR_API_KEYS 未設定なら API 自体を無効（/api/ 配下は 404）にする。
# - 接続元は loopback（127.0.0.1 / ::1）限定。判定は偽装できない REMOTE_ADDR を使う。
# - 認証は Authorization: Bearer <キー> のみ。照合は定数時間比較（キー本体の長さも漏らさない）。
module ApiHelpers
  # API キーの最小長。総当たりを非現実的にするための下限（起動時検証で強制）。
  API_KEY_MIN_LENGTH = 32

  # loopback とみなす接続元アドレス（REMOTE_ADDR）。IPv4/IPv6 のループバックのみ許可する。
  LOOPBACK_ADDRS = ["127.0.0.1", "::1"].freeze

  module_function

  # CALENDAR_API_KEYS（"ラベル:キー" のカンマ区切り）を解析して { ラベル => キー } を返す。
  # 形式不正（ラベル/キー欠落・キーが短い・ラベル重複）は raise して起動を止める
  # （SESSION_SECRET の長さチェックと同じ fail-fast）。空・未設定なら nil（API 無効）を返す。
  def parse_api_keys(raw)
    return nil if raw.to_s.strip.empty?

    keys = {}
    raw.split(",").each do |entry|
      label, key = parse_api_key_entry(entry)
      raise "CALENDAR_API_KEYS: ラベルが重複しています（#{label}）" if keys.key?(label)

      keys[label] = key
    end
    keys
  end

  # 1 エントリ（"ラベル:キー"）を検証して [ラベル, キー] を返す。不正なら raise。
  def parse_api_key_entry(entry)
    label, key = entry.strip.split(":", 2)
    label = label.to_s.strip
    key = key.to_s.strip
    raise "CALENDAR_API_KEYS: 各エントリは 'ラベル:キー' 形式で指定してください" if label.empty? || key.empty?
    raise "CALENDAR_API_KEYS: キーは #{API_KEY_MIN_LENGTH} 文字以上にしてください（ラベル: #{label}）" if key.length < API_KEY_MIN_LENGTH

    [label, key]
  end

  # 接続元が loopback か。X-Forwarded-For に影響されない REMOTE_ADDR で判定する
  # （APP_TRUST_PROXY=true でもスプーフィングで loopback を偽装できないようにする）。
  def loopback?
    LOOPBACK_ADDRS.include?(remote_addr)
  end

  def remote_addr
    request.env["REMOTE_ADDR"].to_s
  end

  # Authorization: Bearer <キー> を検証し、一致したキーのラベルを返す（不一致・ヘッダ無しは nil）。
  # 全キーと定数時間比較（両辺を SHA-256 ダイジェスト化してから secure_compare。
  # 長さ差による早期リターンを避け、キー本体の長さも漏らさない）。
  def authenticate_api_key(keys)
    header = request.env["HTTP_AUTHORIZATION"].to_s
    presented = header[/\ABearer\s+(.+)\z/, 1]
    return nil if presented.nil? || presented.empty?

    presented_digest = Digest::SHA256.digest(presented)
    keys.find { |_label, key| Rack::Utils.secure_compare(presented_digest, Digest::SHA256.digest(key)) }&.first
  end

  # 統一エラーエンベロープ（{"error": {"code", "message"}}）で JSON 応答を返して中断する。
  # 応答はキャッシュさせない（no-store）。code は呼び出し側が使い分ける。
  # 404 は Sinatra が not_found ハンドラで body を上書きするため、ここでは扱わない（404 は halt 404 + not_found 側）。
  def api_error!(status_code, code, message)
    content_type :json
    headers["Cache-Control"] = "no-store"
    halt status_code, JSON.generate("error" => { "code" => code, "message" => message })
  end

  # 成功時の JSON 応答（Content-Type と no-store を付ける）。
  def api_json(payload)
    content_type :json
    headers["Cache-Control"] = "no-store"
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
