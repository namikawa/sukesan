# frozen_string_literal: true

# OAuth 認可フローと、保存済みトークンへのアクセスまわりのヘルパ。
module OAuthHelpers
  # 本番では APP_BASE_URL を固定値として使い、Host ヘッダ汚染の影響を排除する。
  # 未設定（主に開発）の場合はリクエストから組み立てる。
  def base_url
    ENV.fetch("APP_BASE_URL") { "#{request.scheme}://#{request.host_with_port}" }
  end

  def google_redirect_uri
    "#{base_url}/auth/google/callback"
  end

  def microsoft_redirect_uri
    "#{base_url}/auth/microsoft/callback"
  end

  # 認可リクエストに付与する state と PKCE を生成し、セッションに退避する。
  # 返り値は authorize_url にそのまま渡すパラメータ。
  def begin_oauth!
    state = SecureRandom.urlsafe_base64(32)
    verifier = SecureRandom.urlsafe_base64(64)
    session[:oauth_state] = state
    session[:oauth_verifier] = verifier
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    { state: state, code_challenge: challenge, code_challenge_method: "S256" }
  end

  # コールバックの state を検証し（CSRF 対策）、PKCE の code_verifier を返す。
  # 不正・欠落時は中断する。state/verifier は一度きりで破棄する。
  def oauth_verifier!
    expected = session.delete(:oauth_state)
    verifier = session.delete(:oauth_verifier)
    valid = expected && params[:state] && Rack::Utils.secure_compare(expected, params[:state].to_s)
    halt 400, "認可リクエストが無効です。お手数ですが最初からやり直してください。" unless valid

    verifier
  end

  # Google 側でもトークンを失効させる（解除時）。失敗してもローカル削除は続行する。
  def revoke_google_token
    hash = TokenStore.load
    token = hash && (hash["refresh_token"] || hash["access_token"])
    return if token.to_s.empty?

    Net::HTTP.post_form(URI("https://oauth2.googleapis.com/revoke"), "token" => token)
  rescue StandardError
    nil
  end

  # Google トークンは全利用者で共有するためファイルに保存する（公開ページ用）。
  def google_connected?
    !TokenStore.load.nil?
  end

  def google_token
    hash = TokenStore.load
    return nil if hash.nil?

    token = OAuth2::AccessToken.from_hash(OAuthClients.google, hash)
    if token.expired? && token.refresh_token
      token = token.refresh!
      # リフレッシュ後も連携時に取得した管理者メールを保持する。
      TokenStore.save(token.to_hash.merge("admin_email" => hash["admin_email"]))
    end
    token
  end

  # 連携時に保存した管理者（主催者）のメールアドレス。未保存なら nil。
  def google_admin_email
    (TokenStore.load || {})["admin_email"]
  end

  # userinfo エンドポイントから連携アカウントのメールアドレスを取得する（userinfo.email スコープが必要）。
  # 取得に失敗した場合は nil。
  def fetch_google_email(access_token)
    response = access_token.get("https://www.googleapis.com/oauth2/v2/userinfo")
    JSON.parse(response.body)["email"]
  rescue StandardError
    nil
  end

  # Microsoft トークンは Outlook 同期（管理者専用）でのみ使うためセッション保持。
  def microsoft_connected?
    !session[:microsoft_token].nil?
  end

  def microsoft_token
    hash = session[:microsoft_token]
    return nil if hash.nil?

    token = OAuth2::AccessToken.from_hash(OAuthClients.microsoft, hash)
    if token.expired? && token.refresh_token
      token = token.refresh!
      session[:microsoft_token] = token.to_hash
    end
    token
  end
end
