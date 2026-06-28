# frozen_string_literal: true

require "oauth2"

# Google / Microsoft の OAuth2 クライアントを生成する。
# 認可情報は環境変数（.env）から読み込む。
module OAuthClients
  module_function

  # 外部 IdP / API が無応答のときに予約処理のロックを握り続けないよう、接続・読み取りに上限を設ける。
  # この timeout は token 更新だけでなく、同じ client から作る AccessToken 経由のカレンダー API 呼び出しにも効く。
  # 既定は固定値で十分だが、環境ごとの調整用に ENV で上書きできる。
  OPEN_TIMEOUT = ENV.fetch("HTTP_OPEN_TIMEOUT", "5").to_i  # 接続確立の上限（秒）
  READ_TIMEOUT = ENV.fetch("HTTP_READ_TIMEOUT", "15").to_i # レスポンス受信の上限（秒）
  CONNECTION_OPTS = { request: { open_timeout: OPEN_TIMEOUT, timeout: READ_TIMEOUT } }.freeze

  def google
    OAuth2::Client.new(
      ENV.fetch("GOOGLE_CLIENT_ID"),
      ENV.fetch("GOOGLE_CLIENT_SECRET"),
      site: "https://oauth2.googleapis.com",
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      connection_opts: CONNECTION_OPTS
    )
  end

  def microsoft
    tenant = ENV.fetch("MS_TENANT_ID", "common")
    tenant = "common" if tenant.strip.empty?
    base = "https://login.microsoftonline.com/#{tenant}"
    OAuth2::Client.new(
      ENV.fetch("MS_CLIENT_ID"),
      ENV.fetch("MS_CLIENT_SECRET"),
      site: base,
      authorize_url: "#{base}/oauth2/v2.0/authorize",
      token_url: "#{base}/oauth2/v2.0/token",
      connection_opts: CONNECTION_OPTS
    )
  end
end
