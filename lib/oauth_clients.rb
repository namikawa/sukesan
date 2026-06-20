# frozen_string_literal: true

require "oauth2"

# Google / Microsoft の OAuth2 クライアントを生成する。
# 認可情報は環境変数（.env）から読み込む。
module OAuthClients
  module_function

  def google
    OAuth2::Client.new(
      ENV.fetch("GOOGLE_CLIENT_ID"),
      ENV.fetch("GOOGLE_CLIENT_SECRET"),
      site: "https://oauth2.googleapis.com",
      authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token"
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
      token_url: "#{base}/oauth2/v2.0/token"
    )
  end
end
