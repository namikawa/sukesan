# frozen_string_literal: true

# ゲスト（ワンタイム URL の依頼者）向けのルート。調整画面の表示・空き検索、予約の登録、
# 複数候補の仮押さえと決定・削除・全取りやめを扱う。app.rb の末尾から読み込む。

# --- トップ画面（利用案内のみ。調整はワンタイム URL から行う） ---
get "/" do
  @flash = session.delete(:flash)
  erb :home
end

# --- ワンタイム URL の調整画面（発行された token を持つ依頼者だけが利用） ---
get "/t/:token" do
  @token = params[:token].to_s
  @flash = session.delete(:flash)
  @flash_alert = session.delete(:flash_alert) # 入力・状態エラーの警告通知（redirect_with_alert!）
  @form_restore = session.delete(:form_restore) || {} # エラー時に保持した入力値（1 回で消費）
  ticket = TicketStore.find(@token)

  # 仮押さえ中は決定画面（候補一覧・決定・削除）。破壊的操作はホルダー（仮押さえを行った
  # ブラウザ）のみ可能で、URL だけを知る第三者には閲覧のみ許す。
  if TicketStore.held?(ticket)
    @ticket = ticket
    @holder = holder_of?(ticket)
    @holds = ticket["holds"].sort_by { |h| h["slot_start"] }
    @deadline = Time.iso8601(ticket["held_at"]) + TicketStatus::HOLD_TTL_SECONDS
    halt erb(:hold_decision)
  end

  # 無効・期限切れ・使用済み・存在しない token は案内ページを表示する。
  # 410 Gone を返す（404 は not_found ハンドラに横取りされるため使わない）。
  unless TicketStore.active?(ticket)
    forget_holder!(@token) # 終端状態（決定・取りやめ・期限切れ等）の holder キーはセッションから掃除
    @ticket_status = ticket ? TicketStore.status(ticket) : "missing"
    # 会議情報は「登録直後・本人セッション・当該 token」のときだけ表示する。
    completion = session[:completion]
    @completion = completion if completion && completion["token"] == @token
    status 410
    halt erb(:ticket_invalid)
  end

  @expires_label = ticket_expires_label(ticket) # 発行時に選んだ有効期限をゲストへ表示する
  @settings = SettingsStore.load
  @start_date = params[:start_date].to_s
  @end_date = params[:end_date].to_s
  @duration = params[:duration].to_s

  # 検索（Google API 消費）が実際に走る時だけレート制限する。ページ表示だけでは消費しない。
  inputs_present = !@start_date.empty? && !@end_date.empty? && !@duration.empty?
  if google_connected? && inputs_present
    if !SEARCH_LIMITER.allow?(client_ip)
      status 429
      @flash = "空き時間の検索が多すぎます。しばらく時間をおいてから再度お試しください。"
    elsif (google_access = google_token).nil?
      # refresh 失敗など連携トークンが使えない場合は 500 にせず案内を返す（復旧は管理者の再連携で行う）。
      @flash = "現在カレンダーとの連携に問題があるため検索できません。管理者にお問い合わせください。"
    else
      result = availability_search(@settings, google_access).search(
        start_date: @start_date, end_date: @end_date, duration_minutes: @duration.to_i
      )
      @searched = true # 候補一覧（0 件時の案内を含む）を描画するかの画面用フラグ
      @capped = result.capped
      @results = result.days
    end
  end

  # 初回アクセス時のフォーム既定値（翌営業日・30分）。検索はあくまで上の条件でのみ実行する。
  default_date = next_business_day(@settings["business_days"]).strftime("%F")
  @start_date = default_date if @start_date.empty?
  @end_date = default_date if @end_date.empty?
  @duration = "30" if @duration.empty?

  erb :schedule
end

# 選択した空き候補を管理者カレンダーへ登録する（ワンタイム URL からのみ）。
post "/schedule" do
  guard_schedule_rate_limit!

  token = params[:token].to_s
  # 入力・状態のエラーはエラーページでなく、元画面上部の警告通知（flash_alert）で伝える（/hold と統一）。
  # 入力値はエラー後の画面で復元する（redirect_with_alert! が一時保存。文字数はコピー上限で抑える）。
  # "mode" はエラー後にどちらのタブ（登録／仮押さえ）を初期表示するかの判別に使う。
  @form_restore = {
    "mode" => "book",
    "requester" => params[:requester].to_s[0, 200], "title" => params[:title].to_s[0, 200],
    "attendees" => params[:attendees].to_s[0, 2000],
    "video_url" => params[:video_url].to_s[0, ScheduleHelpers::MAX_URL_LENGTH],
    "slot" => params[:slot].to_s,
    "private_event" => params[:private_event].to_s, "send_invites" => params[:send_invites].to_s,
    "request_meet" => params[:request_meet].to_s
  }
  guard_usable_ticket!(token)

  title = params[:title].to_s.strip
  requester = params[:requester].to_s.strip
  starts_at, ends_at = parse_slot(params[:slot])

  redirect_with_alert!(token, "依頼者名・予定名・希望の時間帯を入力してください。") if title.empty? || requester.empty? || starts_at.nil?
  too_long = title.length > MAX_TEXT_LENGTH || requester.length > MAX_TEXT_LENGTH
  redirect_with_alert!(token, "予定名・依頼者名が長すぎます（各 #{MAX_TEXT_LENGTH} 文字以内）。") if too_long
  # 過去・直前すぎる時間帯は、空き再計算（Google 取得）の前に明示的に弾く。
  redirect_with_alert!(token, "過去の時間帯は予約できません。お手数ですが再度空き時間をチェックしてください。") if AvailabilitySearch.too_soon?(starts_at)

  # 任意項目: 参加者メールアドレス・招待メール送付・ビデオ会議 URL・Google Meet 発行・非公開。
  # チェック値は "1" のみ true（任意の文字列を true 扱いにしない）。
  attendees = parse_attendees(params[:attendees])
  video_url = params[:video_url].to_s.strip
  request_meet = params[:request_meet].to_s == "1"
  send_invites = params[:send_invites].to_s == "1"
  private_event = params[:private_event].to_s == "1"

  if (error = optional_event_error(attendees: attendees, video_url: video_url, request_meet: request_meet))
    redirect_with_alert!(token, error)
  end

  event_attendees = attendees_with_admin(attendees)

  ticket_attrs = booking_ticket_attrs(requester: requester, title: title, starts_at: starts_at,
                                      ends_at: ends_at, attendees: attendees)

  event = Event.new(
    source: "google",
    title: EventFormat.summary(title: title, requester: requester),
    starts_at: starts_at,
    ends_at: ends_at,
    all_day: false,
    description: EventFormat.description(requester: requester, video_url: video_url)
  )

  # 連携トークンが使えない（refresh 失敗など）場合は、チケットを消費する前に案内を返す。
  google_access = google_token
  redirect_with_alert!(token, "現在カレンダーとの連携に問題があるため登録できません。管理者にお問い合わせください。") if google_access.nil?

  # 予約の中核トランザクション（空き再確認→token 消費→Google 登録→失敗時ロールバック）は
  # BookingService に委譲する。HTTP ステータスへの写像だけルート側で行う。
  result = booking_service(google_access).call(
    token: token, event: event, ticket_attrs: ticket_attrs,
    attendees: event_attendees, request_meet: request_meet, send_invites: send_invites,
    private_event: private_event
  )

  case result.status
  when :slot_taken
    redirect_with_alert!(token, "選択した時間帯は予約できません。お手数ですが再度空き時間をチェックしてください。")
  when :ticket_used
    redirect_with_alert!(token, "この URL は既に使用されています。")
  # :idempotency_conflict はゲスト経路（token 由来の event id）では返らないが、
  # フォールスルーで成功扱いにしない（fail-open を防ぐ防御）。
  when :api_failure, :idempotency_conflict
    AuditLog.record(:booking_failed, ip: client_ip, target: audit_ticket_id(token))
    redirect_with_alert!(token, "予定の登録に失敗しました。お手数ですが、もう一度お試しください。")
  end

  AuditLog.record(:booking_created, ip: client_ip, target: audit_ticket_id(token))
  slot_label = slack_slot_label(event.starts_at.iso8601, event.ends_at.iso8601)
  notify_booking_created(requester: requester, title: title, slot_label: slot_label)
  # 会議情報は登録直後の本人セッションでだけ完了画面に表示する（チケットには残さない）。
  session[:completion] = { "token" => token, "meet_link" => result.meet_link, "video_url" => video_url }
  session[:flash] = "#{requester} さんの「#{title}」を #{format_dt(event.starts_at)} に登録しました。"
  redirect "/t/#{token}"
end

# --- 複数カレンダー仮押さえ（ワンタイム URL からのみ） ---
# 指定期間の候補から最大 MAX_HOLDS 件を [仮ブロック] としてカレンダーに作成し、チケットを held にする。
post "/hold" do
  guard_schedule_rate_limit!

  token = params[:token].to_s
  # 入力・状態のエラーはエラーページでなく、元画面上部の警告通知（flash_alert）で伝える。
  # 入力値はエラー後の画面で復元する（redirect_with_alert! が一時保存。文字数はコピー上限で抑える）。
  @form_restore = {
    "mode" => "hold",
    "requester" => params[:requester].to_s[0, 200], "title" => params[:title].to_s[0, 200],
    "slots" => Array(params[:slots]).map(&:to_s), "private_event" => params[:private_event].to_s
  }
  guard_usable_ticket!(token)

  title = params[:title].to_s.strip
  requester = params[:requester].to_s.strip
  redirect_with_alert!(token, "依頼者名・予定名を入力してください。") if title.empty? || requester.empty?
  too_long = title.length > MAX_TEXT_LENGTH || requester.length > MAX_TEXT_LENGTH
  redirect_with_alert!(token, "予定名・依頼者名が長すぎます（各 #{MAX_TEXT_LENGTH} 文字以内）。") if too_long

  slots = parse_hold_slots(params[:slots])
  redirect_with_alert!(token, "仮押さえする時間帯を選択してください。") if slots.empty?
  if slots.size > HoldService::MAX_HOLDS
    redirect_with_alert!(token, "仮押さえは最大 #{HoldService::MAX_HOLDS} 件までです。選び直してください。")
  end
  redirect_with_alert!(token, "時間帯の形式が正しくありません。") if slots.any? { |starts_at, _| starts_at.nil? }
  redirect_with_alert!(token, "選択した時間帯が重複しています。重ならないように選び直してください。") if overlapping_slots?(slots)
  redirect_with_alert!(token, "過去の時間帯は仮押さえできません。再度空き時間をチェックしてください。") if slots.any? do |s, _|
    AvailabilitySearch.too_soon?(s)
  end

  google_access = google_token
  redirect_with_alert!(token, "現在カレンダーとの連携に問題があるため仮押さえできません。管理者にお問い合わせください。") if google_access.nil?

  # ホルダーキー: 決定・削除の操作をこのブラウザに限定するための第二要素（チケットとセッションの両方へ保存）。
  holder_key = SecureRandom.urlsafe_base64(32)
  private_event = params[:private_event].to_s == "1" # チェック値は "1" のみ true
  result = hold_service(google_access).hold(token: token, requester: requester, title: title,
                                            slots: slots, holder_key: holder_key,
                                            private_event: private_event)

  case result.status
  when :slot_taken
    redirect_with_alert!(token, "選択した時間帯は予約できなくなりました。再度空き時間をチェックしてください。")
  when :ticket_used
    redirect_with_alert!(token, "この URL は既に使用されています。")
  when :api_failure
    redirect_with_alert!(token, "仮押さえに失敗しました。お手数ですが、もう一度お試しください。")
  end

  remember_holder!(token, holder_key)
  AuditLog.record(:hold_created, ip: client_ip, target: "#{audit_ticket_id(token)} count=#{slots.size}")
  notify_hold_created(slots: slots, requester: requester, title: title)
  session[:flash] = "#{slots.size} 件の日程を仮押さえしました。この画面から 7 日以内に 1 件へ決定してください。"
  redirect "/t/#{token}"
end

# 仮押さえから 1 件に決定する（ホルダーのみ）。任意項目（参加者・ビデオ URL・Meet）はここで指定する。
post "/hold/confirm" do
  guard_schedule_rate_limit!

  token = params[:token].to_s
  ticket = held_ticket_for_holder!(token)

  # エラー時に決定画面の入力値（任意項目・選択スロット）を復元する。
  @form_restore = {
    "slot" => params[:slot].to_s, "attendees" => params[:attendees].to_s[0, 2000],
    "video_url" => params[:video_url].to_s[0, ScheduleHelpers::MAX_URL_LENGTH],
    "request_meet" => params[:request_meet].to_s, "send_invites" => params[:send_invites].to_s
  }

  slot_start = params[:slot].to_s
  redirect_with_alert!(token, "決定する日程を選択してください。") if ticket["holds"].none? { |h| h["slot_start"] == slot_start }

  # チェック値は "1" のみ true（任意の文字列を true 扱いにしない）。
  attendees = parse_attendees(params[:attendees])
  video_url = params[:video_url].to_s.strip
  request_meet = params[:request_meet].to_s == "1"
  send_invites = params[:send_invites].to_s == "1"
  if (error = optional_event_error(attendees: attendees, video_url: video_url, request_meet: request_meet))
    redirect_with_alert!(token, error)
  end

  google_access = hold_google_token!(token)

  event_attendees = attendees_with_admin(attendees)
  result = hold_service(google_access).confirm(token: token, slot_start: slot_start,
                                               attendees: event_attendees, video_url: video_url,
                                               request_meet: request_meet, send_invites: send_invites)
  redirect_with_alert!(token, "この操作は完了済みか、期限切れです。画面を再読み込みしてください。") if result.status == :not_held

  forget_holder!(token)
  AuditLog.record(:hold_confirmed, ip: client_ip, target: audit_ticket_id(token))
  chosen = ticket["holds"].find { |h| h["slot_start"] == slot_start }
  chosen_label = slack_slot_label(slot_start, chosen&.fetch("slot_end", nil))
  notify_hold_confirmed(requester: ticket["requester"], title: ticket["title"], slot_label: chosen_label)
  # 会議情報は決定直後の本人セッションでだけ完了画面に表示する（チケットには残さない）。
  session[:completion] = { "token" => token, "meet_link" => result.meet_link, "video_url" => video_url }
  session[:flash] = "「#{ticket['title']}」を #{format_iso(slot_start)} に決定しました。#{hold_result_notes(result)}".strip
  redirect "/t/#{token}"
end

# 仮押さえから 1 件を削除する（ホルダーのみ）。最後の 1 件を削除するとこの URL は終了する。
post "/hold/delete" do
  guard_schedule_rate_limit!

  token = params[:token].to_s
  held_ticket_for_holder!(token) # 前提（仮押さえ中・ホルダー）の確認のみ。削除後の残件は下で取り直す

  google_access = hold_google_token!(token)

  result = hold_service(google_access).remove(token: token, slot_start: params[:slot].to_s)
  redirect_with_alert!(token, "該当の仮押さえが見つかりません。画面を再読み込みしてください。") if result.status == :not_held

  AuditLog.record(:hold_deleted, ip: client_ip, target: audit_ticket_id(token))
  if TicketStore.held?(TicketStore.find(token))
    session[:flash] = "仮押さえを 1 件削除しました。#{hold_result_notes(result)}".strip
  else
    forget_holder!(token) # 最後の 1 件を削除＝終了（cancelled）
    session[:flash] = "すべての仮押さえを削除したため、この URL は終了しました。#{hold_result_notes(result)}".strip
  end
  redirect "/t/#{token}"
end

# 仮押さえをすべて取りやめて終了する（ホルダーのみ）。
post "/hold/cancel" do
  guard_schedule_rate_limit!

  token = params[:token].to_s
  ticket = held_ticket_for_holder!(token)

  google_access = hold_google_token!(token)

  result = hold_service(google_access).cancel(token: token)
  redirect_with_alert!(token, "この操作は完了済みか、期限切れです。画面を再読み込みしてください。") if result.status == :not_held

  forget_holder!(token)
  AuditLog.record(:hold_cancelled, ip: client_ip, target: audit_ticket_id(token))
  notify_hold_cancelled(holds: ticket["holds"], requester: ticket["requester"], title: ticket["title"])
  session[:flash] = "仮押さえをすべて取りやめました。#{hold_result_notes(result)}".strip
  redirect "/t/#{token}"
end
