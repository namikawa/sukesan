# frozen_string_literal: true

# 認証・リクエスト識別まわりのヘルパ。
module AuthHelpers
  # 管理者かどうか（設定画面・連携操作・Outlook 同期の保護に使う）。
  def admin?
    session[:admin] == true
  end

  def require_admin!
    redirect "/admin" unless admin?
  end

  # 入力されたパスワードを、ENV の bcrypt ダイジェスト（ADMIN_PASSWORD_DIGEST）と照合する。
  # ダイジェスト未設定・不正な形式の場合はログイン不可（false）。
  # BCrypt::Password#is_password? は定数時間で比較する。
  def admin_password_valid?(password)
    digest = ENV.fetch("ADMIN_PASSWORD_DIGEST", "")
    return false if digest.empty?

    BCrypt::Password.new(digest).is_password?(password)
  rescue BCrypt::Errors::InvalidHash
    false
  end

  # レート制限のキーに使うクライアント IP。既定は TCP ピア（REMOTE_ADDR、偽装不可）。
  # 前段プロキシ利用時のみ APP_TRUST_PROXY=true で X-Forwarded-For を信頼する。
  def client_ip
    return request.ip if ENV["APP_TRUST_PROXY"] == "true"

    request.env["REMOTE_ADDR"].to_s
  end

  # フォームに埋め込む CSRF トークン（Rack::Protection::AuthenticityToken と対応）。
  def csrf_token
    Rack::Protection::AuthenticityToken.token(session)
  end
end
