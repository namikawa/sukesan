# frozen_string_literal: true

require "openssl"
require "rack/common_logger"

# アクセスログに秘密を残さないための Rack::CommonLogger。実リクエストの env は書き換えず、
# ログ行の生成にだけマスク済みの複製を使う（ファイル出力・stdout 出力の両方に効く）。
#
# - /t/<token> の token は bearer 資格情報のため、HMAC 短縮 ID（~xxxxxxxx）に置換する。
#   生値は残さず、同一 token のアクセスの突き合わせ（相関）はできる。
# - OAuth callback（/auth/*/callback）のクエリは認可 code を含むため、丸ごと [FILTERED] に置換する。
class MaskedAccessLogger < Rack::CommonLogger
  # /t/ に続く最初のセグメントを token とみなして置換する（実在しないサブパスへのアクセスも含めて隠す）。
  TICKET_PATH_RE = %r{\A(/t/)([^/]+)}
  CALLBACK_PATH_RE = %r{\A/auth/[^/]+/callback\z}

  # token → 短縮 ID の導出。監査ログ等の他のログでも同じ ID で相関できるよう、クラスメソッドで共有する。
  def self.token_short_id(hmac_key, token)
    OpenSSL::HMAC.hexdigest("SHA256", hmac_key, token.to_s)[0, 8]
  end

  # hmac_key: 短縮 ID 導出用の鍵（暗号鍵から用途別派生。app.rb の LOG_TOKEN_ID_KEY）。
  def initialize(app, logger, hmac_key)
    super(app, logger)
    @hmac_key = hmac_key
  end

  private

  def log(env, status, response_headers, began_at)
    super(masked_env(env), status, response_headers, began_at)
  end

  def masked_env(env)
    path = env["PATH_INFO"].to_s
    masked = env.dup
    if TICKET_PATH_RE.match?(path)
      masked["PATH_INFO"] = mask_ticket_path(path)
    elsif CALLBACK_PATH_RE.match?(path) && !env["QUERY_STRING"].to_s.empty?
      masked["QUERY_STRING"] = "[FILTERED]"
    end
    masked
  end

  def mask_ticket_path(path)
    path.sub(TICKET_PATH_RE) do
      "#{Regexp.last_match(1)}~#{self.class.token_short_id(@hmac_key, Regexp.last_match(2))}"
    end
  end
end
