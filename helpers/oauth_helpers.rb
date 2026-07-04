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
  # タイムアウトは他の外部 API 呼び出し（OAuthClients）と同じ上限に揃え、Google 無応答時に
  # 解除の管理操作が長時間ブロックしないようにする（Net::HTTP の既定は 60 秒）。
  def revoke_google_token
    hash = TokenStore.load
    token = hash && (hash["refresh_token"] || hash["access_token"])
    return if token.to_s.empty?

    uri = URI("https://oauth2.googleapis.com/revoke")
    request = Net::HTTP::Post.new(uri)
    request.set_form_data("token" => token)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                        open_timeout: OAuthClients::OPEN_TIMEOUT,
                                        read_timeout: OAuthClients::READ_TIMEOUT) { |http| http.request(request) }
  rescue StandardError
    nil
  end

  # Google トークンは全利用者で共有するためファイルに保存する（公開ページ用）。
  def google_connected?
    !TokenStore.load.nil?
  end

  def google_token
    load_oauth_token(:google, OAuthClients.google)
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

  # Microsoft トークン（Outlook 同期用）も暗号化ファイルに保存し、再起動後も保持する。
  def microsoft_connected?
    !TokenStore.load(:microsoft).nil?
  end

  def microsoft_token
    load_oauth_token(:microsoft, OAuthClients.microsoft)
  end

  # 保存済みトークンを読み、期限切れなら refresh して保存し直す。
  # 期限内ならロックを取らず即返し（ホットパス）、期限切れ時のみ refresh_oauth_token で更新する。
  #
  # refresh 失敗（invalid_grant＝連携取り消し・API 障害・通信エラー等）は 500 にせず nil（未連携扱い）を
  # 返す。一時障害と恒久失効を区別できないため保存トークンは消さない（恒久失効は再連携で復旧する）。
  def load_oauth_token(provider, client)
    hash = TokenStore.load(provider)
    return nil if hash.nil?

    token = OAuth2::AccessToken.from_hash(client, hash)
    return token unless token.expired? && token.refresh_token

    refresh_oauth_token(provider, client)
  rescue OAuth2::Error, Faraday::Error => e
    warn "[oauth] トークン更新失敗 (provider=#{provider}): #{e.class}（未連携として扱います）"
    nil
  end

  # プロバイダ別ロック内で再読込→再判定→refresh→save を行い、並行 refresh や保存競合を防ぐ
  # （ダブルチェックロック）。保存は hash.merge(token.to_hash) で、トークン項目だけ更新し
  # 追加キー（admin_email 等）を保つ。
  def refresh_oauth_token(provider, client)
    TokenStore.with_lock(provider) do
      hash = TokenStore.load(provider)
      next nil if hash.nil?

      token = OAuth2::AccessToken.from_hash(client, hash)
      if token.expired? && token.refresh_token
        token = token.refresh!
        TokenStore.save(hash.merge(token.to_hash), provider)
      end
      token
    end
  end
end
