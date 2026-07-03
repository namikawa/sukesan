# frozen_string_literal: true

# 認証・リクエスト識別まわりのヘルパ。
module AuthHelpers
  # 管理者セッションの有効期間（秒）。セッション Cookie の expire_after にも同じ値を使う。
  # Cookie の期限（Expires 属性）はブラウザ任せで、署名済み Cookie 自体は無期限に有効なため、
  # サーバ側でもログイン時刻からの経過を検証し、窃取・複製された Cookie の有効期間をこの長さに限定する。
  ADMIN_SESSION_TTL = 24 * 60 * 60

  # 管理者かどうか（設定画面・連携操作・Outlook 同期の保護に使う）。
  # admin_at（ログイン時刻）が無い・古いセッションは管理者扱いしない（fail-closed）。
  def admin?
    session[:admin] == true &&
      (Time.now.to_i - session[:admin_at].to_i) < ADMIN_SESSION_TTL
  end

  # 状態変更（POST）やアクション（OAuth 開始等）のゲート。未認証は /admin へリダイレクトする。
  def require_admin!
    redirect "/admin" unless admin?
  end

  # 管理ページ（GET）のゲート。flash を取り出し、未認証ならその URL のままログイン画面を
  # 描画して中断する（ログイン後に元のページへ戻れる）。全管理ページで挙動を統一する。
  def require_admin_page!
    @flash = session.delete(:flash)
    halt erb(:login) unless admin?
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

  # HTTPS で受けているか。前段プロキシ（Cloud Run 等）で TLS 終端しコンテナへは HTTP で届く構成では、
  # APP_TRUST_PROXY=true のとき X-Forwarded-Proto を信頼して判定する（Rack の forwarded 信頼設定に依存せず、
  # 本番の HTTPS 強制リダイレクトがループしないようにする）。偽装防止のため信頼はオプトイン。
  def request_secure?
    return true if request.secure?
    return false unless ENV["APP_TRUST_PROXY"] == "true"

    forwarded = request.get_header("HTTP_X_FORWARDED_PROTO").to_s.split(",").first
    forwarded&.strip&.downcase == "https"
  end

  # フォームに埋め込む CSRF トークン（Rack::Protection::AuthenticityToken と対応）。
  def csrf_token
    Rack::Protection::AuthenticityToken.token(session)
  end

  # URL（bearer な token URL）・登録内容・会議リンク・管理情報を扱う画面か。
  # 該当画面はブラウザ・プロキシにキャッシュさせない（no-store）。静的アセットや公開トップは対象外。
  SENSITIVE_PREFIXES = ["/admin", "/settings", "/sync", "/tickets"].freeze
  def no_store?(path)
    path.start_with?("/t/") ||
      SENSITIVE_PREFIXES.include?(path) ||
      SENSITIVE_PREFIXES.any? { |prefix| path.start_with?("#{prefix}/") }
  end
end
