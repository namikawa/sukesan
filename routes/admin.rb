# frozen_string_literal: true

# 管理者向けのルート。ログイン・ワンタイム URL の発行/一覧/無効化・設定・API キー管理・
# Google/Microsoft の OAuth 連携・Outlook 同期を扱う。app.rb の末尾から読み込む。

# --- 管理者ログイン ---
post "/settings/login" do
  # 失敗回数だけを数える。bcrypt 計算の前に弾くことで CPU 消耗型の総当たりも防ぐ。
  halt 429, "ログイン試行が多すぎます。しばらく時間をおいてからお試しください。" if LOGIN_LIMITER.exceeded?(client_ip)

  if admin_password_valid?(params[:password].to_s)
    session.options[:renew] = true # セッション固定対策: ログイン時に session id を再生成
    session[:admin] = true
    session[:admin_at] = Time.now.to_i # サーバ側 TTL 検証用のログイン時刻（AuthHelpers#admin?）
    AuditLog.record(:login_success, ip: client_ip)
  else
    LOGIN_LIMITER.record(client_ip) # 失敗時のみ記録（成功ログインは制限を消費しない）
    AuditLog.record(:login_failure, ip: client_ip)
    session[:flash] = "パスワードが正しくありません。"
  end
  # 成功時はログイン画面を出した元の管理ページへ戻す。失敗時も同じページへ戻し、
  # 未認証のため再びログイン画面が描画される（return_to も自然に維持される）。
  # 戻り先は許可リストで検証し、許可外は /admin へフォールバック（open redirect 防止）。
  redirect login_return_to(params[:return_to])
end

post "/settings/logout" do
  session.clear
  session.options[:drop] = true # ログアウト時はセッションを破棄する
  redirect "/admin"
end

# --- 管理者トップ（各ツールへの導線ハブ。認証していなければログイン画面を表示） ---
get "/admin" do
  require_admin_page!
  erb :admin
end

# --- Google カレンダー調整ツール（ワンタイム URL の発行・一覧。認証していなければログイン画面を表示） ---
get "/tickets" do
  require_admin_page!
  # 一覧は直近 30 日分（TicketStore.all 側で絞り込み済み）。件数・ページの解釈は PaginationHelpers に集約。
  page = paginate(TicketStore.all)
  @tickets = page.items
  @page = page.page
  @per = page.per
  @total = page.total
  @total_pages = page.total_pages
  erb :tickets
end

# --- 設定（管理者専用：認証していなければログイン画面を表示） ---
get "/settings" do
  require_admin_page!
  @settings = SettingsStore.load
  # 発行直後の API キーは本人セッションで一度だけ表示する（取り出しと同時に削除。再表示不可）。
  @new_api_key = session.delete(:new_api_key)
  erb :settings
end

# 1回限りのスケジュール調整 URL を発行する（管理者専用）。
post "/tickets" do
  require_admin!
  # 有効期限は許可値（24/72/168 時間）のみ受け付け、許可外・欠落は既定の 24 時間に落とす（fail-closed）。
  ttl_hours = TicketStatus.normalize_ttl_hours(params[:ttl_hours])
  token = TicketStore.create(ttl_hours: ttl_hours)
  AuditLog.record(:ticket_create, ip: client_ip, target: audit_ticket_id(token))
  session[:flash] = "ワンタイム URL を発行しました。"
  redirect "/tickets"
end

# 発行済みワンタイム URL を手動で無効化する（管理者専用）。
# 仮押さえ中だったチケットは、残っている [仮ブロック] イベントも削除する（URL 漏えい・放置時の kill switch）。
# token は URL でなく POST body（hidden input）で受け取る。生 token は bearer 資格情報であり、
# URL に載せるとアクセスログ（マスク対象は /t/<token> のみ）へそのまま記録されてしまうため。
post "/tickets/revoke" do
  require_admin!
  token = params[:token].to_s
  previous = TicketStore.revoke(token)
  failed = previous.is_a?(Hash) ? delete_hold_events(Array(previous["holds"])) : 0
  AuditLog.record(:ticket_revoke, ip: client_ip, target: audit_ticket_id(token))
  session[:flash] = "ワンタイム URL を無効化しました。"
  session[:flash] += " ※#{failed} 件の仮押さえイベントを削除できませんでした。" if failed.positive?
  redirect "/tickets"
end

post "/settings" do
  require_admin!
  values = settings_params
  if settings_valid?(values)
    SettingsStore.save(values)
    AuditLog.record(:settings_update, ip: client_ip)
    session[:flash] = "設定を保存しました。"
  else
    session[:flash] = "入力内容が正しくありません（時間は HH:MM・開始 < 終了、休憩は 0 分以上で入力してください）。"
  end
  redirect "/settings"
end

post "/settings/google/disconnect" do
  require_admin!
  revoke_google_token
  TokenStore.clear
  AuditLog.record(:oauth_disconnect, ip: client_ip, target: "google")
  session[:flash] = "Google 連携を解除しました。"
  redirect "/settings"
end

# 他システム向け API のキーを発行する（管理者専用）。
# 生のキーは保存せず SHA-256 ダイジェストのみ SettingsStore に持つ。生のキーはセッション経由で
# 発行直後の画面に一度だけ表示する（GET /settings 側で取り出しと同時に削除）。
post "/settings/api_keys" do
  require_admin!
  label = params[:label].to_s.strip
  keys = stored_api_keys
  if (error = api_key_label_error(label, keys))
    session[:flash] = error
    redirect "/settings"
  end

  # 権限は許可値（read/write）のみ受け付け、許可外・欠落は read に落とす（fail-closed）。
  scope = normalize_api_key_scope(params[:scope])
  key = SecureRandom.hex(32)
  entry = { "digest" => Digest::SHA256.hexdigest(key), "created_at" => Time.now.iso8601, "scope" => scope }
  SettingsStore.save("api_keys" => keys.merge(label => entry))
  AuditLog.record(:api_key_issued, ip: client_ip, target: "#{label} scope=#{scope}")
  session[:new_api_key] = { "label" => label, "key" => key }
  session[:flash] = "API キーを発行しました。キーはこの画面でのみ表示されます。"
  redirect "/settings"
end

# 発行済みの API キーを削除する（管理者専用）。削除したキーは即座に認証不可になる。
# 対象ラベルはフォームパラメータで受け取る（URL パスに埋めない）。
post "/settings/api_keys/delete" do
  require_admin!
  label = params[:label].to_s
  keys = stored_api_keys
  if keys.key?(label)
    SettingsStore.save("api_keys" => keys.except(label))
    AuditLog.record(:api_key_revoked, ip: client_ip, target: label)
    session[:flash] = "API キーを削除しました。"
  else
    session[:flash] = "指定された API キーが見つかりません。"
  end
  redirect "/settings"
end

# --- Outlook 同期（管理者専用） ---
get "/sync" do
  require_admin_page!
  @settings = SettingsStore.load
  # チェック直後の表示は 1 回だけ（POST /check で立てたフラグを消費）。更新・再表示時はフラグが無いので
  # 前回の取得範囲を破棄し、未チェック状態に戻す（古い結果を残さない）。
  clear_sync_window unless session.delete(:sync_show)
  @test_mode = sync_test_mode?
  window = current_sync_window
  @checked = !window.nil?
  # 差分はキャッシュせず、取得範囲から都度再計算する（常に最新）。
  @events = if window && google_connected? && microsoft_connected?
              compute_outlook_only(window)
            else
              []
            end
  # nil はトークンが使えない（refresh 失敗など）。「該当なし」と誤認させず、再連携を促す。
  if @events.nil?
    @checked = false
    @events = []
    @flash ||= "カレンダー連携の更新に失敗しました。お手数ですが、連携を解除して再度連携してください。"
  end
  erb :sync
end

# --- Google OAuth（連携は管理者のみ。トークンは共有保存する） ---
get "/auth/google" do
  require_admin!
  redirect OAuthClients.google.auth_code.authorize_url(
    # calendar.events に加え、主催者メール取得のため userinfo.email を要求する。
    redirect_uri: google_redirect_uri,
    scope: "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/userinfo.email",
    access_type: "offline",
    prompt: "consent",
    **begin_oauth!
  )
end

get "/auth/google/callback" do
  require_admin!
  verifier = oauth_verifier!
  halt 400, "連携がキャンセルされました。" if params[:code].to_s.empty?

  token = OAuthClients.google.auth_code.get_token(
    params[:code], redirect_uri: google_redirect_uri, code_verifier: verifier
  )
  # 連携時に主催者（管理者）のメールを取得し、トークンと一緒に保存する。
  TokenStore.save(token.to_hash.merge("admin_email" => fetch_google_email(token)))
  AuditLog.record(:oauth_connect, ip: client_ip, target: "google")
  session[:flash] = "Google と連携しました。"
  redirect "/settings"
end

# --- Microsoft OAuth（Outlook 同期用。管理者のみ） ---
get "/auth/microsoft" do
  require_admin!
  redirect OAuthClients.microsoft.auth_code.authorize_url(
    redirect_uri: microsoft_redirect_uri,
    scope: "offline_access https://graph.microsoft.com/Calendars.Read",
    **begin_oauth!
  )
end

get "/auth/microsoft/callback" do
  require_admin!
  verifier = oauth_verifier!
  halt 400, "連携がキャンセルされました。" if params[:code].to_s.empty?

  token = OAuthClients.microsoft.auth_code.get_token(
    params[:code], redirect_uri: microsoft_redirect_uri, code_verifier: verifier
  )
  TokenStore.save(token.to_hash, :microsoft)
  AuditLog.record(:oauth_connect, ip: client_ip, target: "microsoft")
  redirect "/sync"
end

post "/disconnect" do
  require_admin!
  TokenStore.clear(:microsoft)
  clear_sync_window
  AuditLog.record(:oauth_disconnect, ip: client_ip, target: "microsoft")
  redirect "/sync"
end

# --- 差分チェック（管理者専用） ---
# 取得範囲は日数（当日0:00起点）または日付範囲で指定。テストモードは差分表示のみ。
post "/check" do
  require_admin!
  halt 400, "Google と Outlook の両方の連携が必要です" unless google_connected? && microsoft_connected?

  window, error = resolve_sync_window(params)
  if error
    session[:flash] = error
    redirect "/sync"
  end

  # 差分はここでは取得せず、取得範囲とテストモードだけ保存する（表示時に再計算）。
  store_sync_window(window, test_mode: params[:test_mode] == "1")
  session[:sync_show] = true # チェック直後の表示は 1 回だけ（更新・再表示では結果を残さない）
  redirect "/sync"
end

# --- 同期（選択したイベントのみ Google へ反映。管理者専用） ---
post "/sync" do
  require_admin!
  halt 400, "Google と Outlook の両方の連携が必要です" unless google_connected? && microsoft_connected?
  # テストモードでチェックした直後は反映しない（誤適用防止）。
  if sync_test_mode?
    session[:flash] = "テストモードのため反映しません。反映するにはテストモードを外して再チェックしてください。"
    redirect "/sync"
  end

  window = current_sync_window
  unless window
    session[:flash] = "取得範囲が見つかりません。もう一度チェックしてください。"
    redirect "/sync"
  end

  # 反映直前に差分を取り直し、選択のうち「今も Outlook 側にのみ存在する」ものだけ登録する。
  # 既に Google にあるもの（前回反映済み含む）は差分から外れるため、二重作成にならない。
  # 選択は一意な external_id で照合する（同一件名・同一時刻の重複イベントを取り違えないため）。
  selected = Array(params[:selected])
  google_access = google_token
  events = google_access && compute_outlook_only(window)
  # nil はトークンが使えない（refresh 失敗など）。反映せず再連携を促す。
  if events.nil?
    session[:flash] = "カレンダー連携の更新に失敗しました。お手数ですが、連携を解除して再度連携してください。"
    redirect "/sync"
  end

  # 反映は 1 件ずつ失敗を切り分け、部分失敗はエラーページでなく件数付きの通知で伝える
  # （登録済み分は次回チェックの差分から自然に消えるため、再チェック→残りの再選択で復旧できる）。
  client = GoogleCalendarClient.new(google_access)
  targets = events.select { |event| selected.include?(event.external_id) }
  failed = targets.count do |event|
    client.create_event(event)
    false
  rescue StandardError => e
    warn "[sync] イベントの同期失敗: #{e.class}"
    true
  end
  session[:flash] =
    if failed.zero?
      "選択したイベントを Google に同期しました。"
    else
      "#{targets.size - failed} 件を同期しました（#{failed} 件は失敗しました。もう一度チェックしてお試しください）。"
    end
  redirect "/sync"
end
