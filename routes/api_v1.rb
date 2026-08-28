# frozen_string_literal: true

# 他システム向け JSON API のルート定義（app.rb の末尾から読み込む）。応答の整形は ApiSerializers に委ねる。

# --- 他システム向け API（/api/v1/…。同一マシン上の別システムから利用する JSON API） ---
# 認証・認可（deny-by-default）は before フィルタでまとめて行い、各ルートは業務ロジックに徹する。
# セッションは使わない・変更しない（API はステートレス）。
before "/api/*" do
  # 発行済みキー（管理画面で発行・ダイジェスト保存）が 1 つもなければ API 自体が存在しない扱い。
  # 404 は not_found ハンドラが body を組み立てる（API パスなら JSON エンベロープ）。
  api_keys = stored_api_keys
  halt 404 if api_keys.empty?

  # loopback 限定。偽装できない REMOTE_ADDR で判定する（APP_TRUST_PROXY=true でも X-Forwarded-For は見ない）。
  api_error!(403, "forbidden", "この API はローカルホストからのみ利用できます。") unless loopback?

  # Authorization: Bearer <キー> のみ。一致したキーのラベルを以後の識別子（レート制限・監査）に、
  # スコープを書き込み系の認可（require_write_scope!）に使う。
  @api_label, @api_scope = authenticate_api_key(api_keys)
  if @api_label.nil?
    AuditLog.record(:api_auth_failed, ip: remote_addr)
    api_error!(401, "unauthorized", "認証に失敗しました。")
  end

  # レート制限はキーのラベル単位（IP ではなくキーで数える）。
  api_error!(429, "rate_limited", "リクエストが多すぎます。しばらく時間をおいてください。") unless API_LIMITER.allow?(@api_label)

  # 書き込み系（POST）は write スコープを必須とし、より厳しいレート制限を重ねる。
  # ルートごとに書くと適用漏れが起きるため、ここで一律に課す（この API は POST＝書き込み）。
  if request.post?
    require_write_scope!
    api_error!(429, "rate_limited", "書き込みが多すぎます。しばらく時間をおいてください。") unless API_WRITE_LIMITER.allow?(@api_label)
  end
end

# 指定日（既定は今日）の Google カレンダーのイベント一覧を返す。
get "/api/v1/calendars/google/events" do
  # date は任意。省略時はアプリのタイムゾーンでの「今日」。不正な形式は 400。
  date_param = params[:date].to_s
  date = if date_param.empty?
           Date.today
         else
           begin
             Date.iso8601(date_param)
           rescue ArgumentError
             api_error!(400, "invalid_date", "date は YYYY-MM-DD 形式で指定してください。")
           end
         end

  # 対象期間はその日の 0:00 から翌日 0:00（ローカルタイム）。
  time_min = Time.local(date.year, date.month, date.day)
  time_max = time_min + (24 * 60 * 60)

  google_access = api_google_token!

  # Google API 呼び出しの失敗は詳細を出さず upstream_error に丸める（トークン等を漏らさない）。
  begin
    events = GoogleCalendarClient.new(google_access).list_events(time_min: time_min, time_max: time_max)
  rescue StandardError => e
    warn "[api] Google イベント取得失敗: #{e.class}"
    api_error!(502, "upstream_error", "カレンダーの取得に失敗しました。")
  end

  api_json(
    "date" => date.strftime("%F"),
    "events" => events.map { |event| api_event(event) }
  )
end

# 指定期間・所要時間の空き候補を返す（ゲスト画面の検索と同じロジック・制約）。
get "/api/v1/availability" do
  start_date = api_date_param!(:start_date)
  end_date = api_date_param!(:end_date)
  duration_minutes = api_duration_param!(:duration_minutes)

  google_access = api_google_token!

  settings = SettingsStore.load
  begin
    result = availability_search(settings, google_access)
             .search(start_date: start_date.to_s, end_date: end_date.to_s, duration_minutes: duration_minutes)
  rescue StandardError => e
    warn "[api] 空き候補の検索失敗: #{e.class}"
    api_error!(502, "upstream_error", "空き候補の取得に失敗しました。")
  end

  api_json(api_availability(result, duration_minutes))
end

# 発行済みチケットの一覧（管理画面 /tickets の API 版。予約・仮押さえも内部チケットとしてここに並ぶ）。
# 対象は TicketStore.all と同じ直近 30 日分（新しい順）。
get "/api/v1/tickets" do
  status_filter = api_ticket_status_param!(:status)
  tickets = TicketStore.all
  tickets = tickets.select { |ticket| TicketStore.status(ticket) == status_filter } if status_filter

  # ページングは管理画面と同じ流儀（PaginationHelpers に集約）。
  page = paginate(tickets)

  api_json(
    "tickets" => page.items.map { |ticket| api_ticket(ticket, id: audit_ticket_id(ticket["token"])) },
    "page" => page.page,
    "total_pages" => page.total_pages
  )
end

# チケット 1 件の詳細（識別子は一覧と同じ HMAC 短縮 ID）。
get "/api/v1/tickets/:id" do
  ticket = find_ticket_by_api_id(params[:id].to_s)
  halt 404 if ticket.nil? # body は not_found ハンドラが JSON エンベロープで組み立てる

  payload = api_ticket(ticket, id: audit_ticket_id(ticket["token"]))
  # ワンタイム URL（生 token）を返すのは write スコープかつ未使用（active）のときだけ。
  # 依頼者へ URL を渡し直すユースケース向けで、read キー・使用済みには含めない。
  payload["url"] = ticket_url(ticket["token"]) if @api_scope == "write" && payload["status"] == "active"
  api_json(payload)
end

# ワンタイム URL を発行する（管理画面 POST /tickets の API 版）。発行直後のここでだけ生 token を含む
# URL を返す（依頼者へ渡すため。以後は write スコープでの詳細取得＝active のときのみ再取得できる）。
post "/api/v1/tickets" do
  body = api_json_body!
  # 有効期限は許可値（24/72/168 時間）のみ受け付け、許可外・欠落は既定の 24 時間に落とす（fail-closed）。
  ttl_hours = TicketStatus.normalize_ttl_hours(body["ttl_hours"])
  token = TicketStore.create(ttl_hours: ttl_hours)
  ticket = TicketStore.find(token)
  AuditLog.record(:ticket_create, ip: remote_addr, target: "#{audit_ticket_id(token)} via=api:#{@api_label}")

  status 201
  api_json(
    "id" => audit_ticket_id(token),
    "url" => ticket_url(token),
    "status" => "active",
    "ttl_hours" => ttl_hours,
    "created_at" => ticket["created_at"],
    "expires_at" => api_time(TicketStatus.expires_at(ticket))
  )
end

# 発行済みチケットを無効化する（管理画面 POST /tickets/revoke の API 版＝URL 漏えい・放置時の kill switch）。
# 仮押さえ中だったチケットは、残っている [仮ブロック] イベントも削除する。
post "/api/v1/tickets/:id/revoke" do
  ticket = find_ticket_by_api_id(params[:id].to_s)
  halt 404 if ticket.nil? # body は not_found ハンドラが JSON エンベロープで組み立てる

  token = ticket["token"]
  # 受理されるのは active / held のみ（既存の遷移）。終端・期限切れ・破損は状態不一致として 409。
  previous = TicketStore.revoke(token)
  api_error!(409, "invalid_state", "このチケットは無効化できる状態ではありません。") unless previous.is_a?(Hash)

  failed = delete_hold_events(Array(previous["holds"]))
  AuditLog.record(:ticket_revoke, ip: remote_addr, target: "#{audit_ticket_id(token)} via=api:#{@api_label}")
  api_json("id" => audit_ticket_id(token), "status" => "revoked", "failed_deletes" => failed)
end

# 確定済みの枠を管理者カレンダーへ直接登録する（相手との調整を終えた外部システムからの予約）。
# 内部でチケットを 1 枚発行して即消費し、ゲストの登録（POST /schedule）と同じ BookingService の
# トランザクション（空き再確認 → use! → Google 登録 → 失敗時ロールバック）に載せる。
post "/api/v1/bookings" do
  body = api_json_body!
  starts_at, ends_at = api_slot_param!(body)
  requester = api_text_param!(body, "requester")
  title = api_text_param!(body, "title")
  attendees = api_attendees_param!(body)
  video_url = api_optional_text_param!(body, "video_url")
  request_meet = api_boolean_param!(body, "request_meet")
  send_invites = api_boolean_param!(body, "send_invites")
  private_event = api_boolean_param!(body, "private_event")
  # 任意項目（件数・メール形式・URL 形式・Meet との排他）はゲストの登録と同一の検証・文言を使う。
  if (error = optional_event_error(attendees: attendees, video_url: video_url, request_meet: request_meet))
    api_error!(400, "invalid_params", error)
  end
  idempotency_key = api_idempotency_key!

  # 同じ Idempotency-Key の予約が既にあれば、新規登録せず保存内容から応答する（リトライのリプレイ）。
  if idempotency_key && (booked = find_booking_by_idempotency_key(idempotency_key))
    halt 200, api_json(api_booking(booked, id: audit_ticket_id(booked["token"])))
  end

  # 連携トークンが使えない（未連携・refresh 失敗）場合は、チケットを発行する前に返す。
  google_access = api_google_token!

  event = Event.new(source: "google", title: EventFormat.summary(title: title, requester: requester),
                    starts_at: starts_at, ends_at: ends_at, all_day: false,
                    description: EventFormat.description(requester: requester, video_url: video_url))

  ticket_attrs = booking_ticket_attrs(requester: requester, title: title, starts_at: starts_at,
                                      ends_at: ends_at, attendees: attendees)
  # Idempotency-Key はリプレイ検索の鍵として API 経由の予約にだけ持たせる。
  ticket_attrs["idempotency_key"] = idempotency_key if idempotency_key

  # 内部チケットを 1 枚発行し、そのまま消費する（API 経由の予約も既存の状態機械・一覧・revoke に載る）。
  token = TicketStore.create
  result = booking_service(google_access).call(
    token: token, event: event, ticket_attrs: ticket_attrs,
    attendees: attendees_with_admin(attendees), request_meet: request_meet,
    send_invites: send_invites, private_event: private_event,
    event_id: idempotency_event_id(idempotency_key)
  )

  unless result.status == :ok
    # 内部チケットは誰にも渡していないため、active に戻さず終端させる（一覧にゴミを残さない）。
    # 後始末のための無効化なので監査には残さない（記録するのは予約の成否）。
    TicketStore.revoke(token)
    api_error!(409, "slot_taken", "この時間帯は登録できません。空き候補を取り直してください。") if result.status == :slot_taken

    AuditLog.record(:booking_failed, ip: remote_addr, target: "#{audit_ticket_id(token)} via=api:#{@api_label}")
    # キー由来の event id が Google 側に既にある＝取り消して削除した予約と同じキーでの再登録
    # （削除したイベントの ID は再利用できない）。予定を作れていないため成功にはしない。
    if result.status == :idempotency_conflict
      api_error!(409, "idempotency_conflict",
                 "この Idempotency-Key は過去の予約で使用されています。新しいキーを指定してください。")
    end

    # :api_failure（Google 登録失敗）。:ticket_used は発行直後のチケットのため通常起きない。
    api_error!(502, "upstream_error", "予定の登録に失敗しました。")
  end

  AuditLog.record(:booking_created, ip: remote_addr, target: "#{audit_ticket_id(token)} via=api:#{@api_label}")
  notify_booking_created(requester: requester, title: title, via: @api_label,
                         slot_label: slack_slot_label(starts_at.iso8601, ends_at.iso8601))
  status 201
  api_json(api_booking(TicketStore.find(token), id: audit_ticket_id(token), meet_link: result.meet_link))
end

# 確定済みの予約（used）を取り消す（used → cancelled）。チケットに保存した event_id の予定を
# Google から削除する。削除対象はチケット保存値のみで、クライアントから event id は受け取らない
# （任意イベント削除への横展開を防ぐ既存原則）。
post "/api/v1/bookings/:id/cancel" do
  ticket = find_ticket_by_api_id(params[:id].to_s)
  halt 404 if ticket.nil? # body は not_found ハンドラが JSON エンベロープで組み立てる

  body = api_json_body!
  # 参加者へのキャンセル通知は既定で送らない（招待メールを送った予約を取り消すときだけ opt-in）。
  notify_attendees = api_boolean_param!(body, "notify_attendees")

  # 予定を削除できない状態（未連携・refresh 失敗）でチケットだけ取消済みにしないよう、遷移の前に確認する。
  google_access = api_google_token!

  # 遷移（used → cancelled）と予定の削除は BOOKING_LOCK 内でまとめて行う。予約の登録・仮押さえの決定は
  # ロック内で「チケット遷移 → Google 操作」を行うため、その途中に割り込むと取消した予定が作られ直す・
  # 削除済みの予定へ patch するといった食い違いが起き得る。halt はロックの外で行う。
  token = ticket["token"]
  previous, event_deleted = BOOKING_LOCK.synchronize do
    # 受理されるのは event_id を保存した used のみ（未使用・仮押さえ中・終端・event_id 未保存は不受理）。
    prev = TicketStore.cancel_booking!(token)
    next [nil, false] unless prev.is_a?(Hash)

    [prev, delete_booking_event(google_access, prev["event_id"], notify_attendees: notify_attendees)]
  end
  api_error!(409, "invalid_state", "この予約は取り消せる状態ではありません。") if previous.nil?

  AuditLog.record(:booking_cancelled, ip: remote_addr, target: "#{audit_ticket_id(token)} via=api:#{@api_label}")
  # 削除に失敗した予定はカレンダーに残るため、管理者が手動で消せるよう通知にも明記する。
  note = event_deleted ? "" : "\n※カレンダーの予定を削除できませんでした（手動で削除してください）。"
  notify_booking_cancelled(requester: previous["requester"], title: previous["title"], note: note,
                           via: @api_label,
                           slot_label: slack_slot_label(previous["slot_start"], previous["slot_end"]))
  api_json("id" => audit_ticket_id(token), "status" => "cancelled", "event_deleted" => event_deleted)
end

# 複数の候補を [仮ブロック] として確保する（ゲストの仮押さえ POST /hold の API 版）。内部でチケットを
# 1 枚発行して held にし、既存の状態機械（held → used / cancelled）と管理画面・kill switch に載せる。
# holder_key は生成してチケットに保存するが、API はセッションを持たないため照合には使わない
# （write スコープのキー＝管理者相当。ゲストが仮押さえたチケットも API から操作できる＝設計上の裁定）。
post "/api/v1/holds" do
  body = api_json_body!
  slots = api_hold_slots_param!(body)
  requester = api_text_param!(body, "requester")
  title = api_text_param!(body, "title")
  private_event = api_boolean_param!(body, "private_event")

  # 連携トークンが使えない（未連携・refresh 失敗）場合は、チケットを発行する前に返す。
  google_access = api_google_token!

  token = TicketStore.create
  result = hold_service(google_access).hold(token: token, requester: requester, title: title, slots: slots,
                                            holder_key: SecureRandom.urlsafe_base64(32),
                                            private_event: private_event)
  unless result.status == :ok
    # 失敗時のチケットは active のまま残る（:slot_taken は遷移前・:api_failure は HoldService が
    # reactivate! で巻き戻し済み）。誰にも渡していない内部チケットなので終端させる（一覧のゴミにしない）。
    # 後始末のための無効化なので監査には残さない（ゲストの仮押さえも失敗は記録しない）。
    TicketStore.revoke(token)
    api_error!(409, "slot_taken", "指定した時間帯は仮押さえできません。空き候補を取り直してください。") if result.status == :slot_taken

    # :api_failure（[仮ブロック] の作成失敗）。:ticket_used は発行直後のチケットのため通常起きない。
    api_error!(502, "upstream_error", "仮押さえの作成に失敗しました。")
  end

  ticket = TicketStore.find(token)
  # 件数の併記はゲストの仮押さえと同形（target への併記が付随情報の既存の流儀）。
  audit_target = "#{audit_ticket_id(token)} via=api:#{@api_label} count=#{slots.size}"
  AuditLog.record(:hold_created, ip: remote_addr, target: audit_target)
  notify_hold_created(slots: slots, requester: requester, title: title, via: @api_label)
  status 201
  api_json("id" => audit_ticket_id(token), "status" => "held",
           "expires_at" => api_time(TicketStatus.expires_at(ticket)),
           "slots" => api_hold_slots(ticket["holds"]))
end

# 仮押さえから 1 件を決定する（held → used）。選択したイベントを確定形へ更新し、他の候補は削除する。
post "/api/v1/holds/:id/confirm" do
  ticket = api_held_ticket!(params[:id].to_s)
  body = api_json_body!
  slot_start = api_hold_slot_param!(ticket, body)
  attendees = api_attendees_param!(body)
  video_url = api_optional_text_param!(body, "video_url")
  request_meet = api_boolean_param!(body, "request_meet")
  send_invites = api_boolean_param!(body, "send_invites")
  # 任意項目（件数・メール形式・URL 形式・Meet との排他）はゲストの決定と同一の検証・文言を使う。
  if (error = optional_event_error(attendees: attendees, video_url: video_url, request_meet: request_meet))
    api_error!(400, "invalid_params", error)
  end

  google_access = api_google_token!

  token = ticket["token"]
  result = hold_service(google_access).confirm(token: token, slot_start: slot_start,
                                               attendees: attendees_with_admin(attendees), video_url: video_url,
                                               request_meet: request_meet, send_invites: send_invites)
  # 状態確認からロック取得までの間に他経路（ゲスト画面・別の API 呼び出し）で決定・取りやめが起きた場合。
  api_error!(409, "invalid_state", "この仮押さえは決定できる状態ではありません。") if result.status == :not_held

  AuditLog.record(:hold_confirmed, ip: remote_addr, target: "#{audit_ticket_id(token)} via=api:#{@api_label}")
  confirmed = TicketStore.find(token)
  notify_hold_confirmed(requester: confirmed["requester"], title: confirmed["title"], via: @api_label,
                        slot_label: slack_slot_label(confirmed["slot_start"], confirmed["slot_end"]))
  api_json(api_hold_confirmation(confirmed, id: audit_ticket_id(token), result: result))
end

# 仮押さえから候補を 1 件だけ取り除く（対応する [仮ブロック] も削除する）。
# 最後の 1 件を取り除いた場合はチケットが終了（cancelled）する（既存挙動）。
post "/api/v1/holds/:id/slots/delete" do
  ticket = api_held_ticket!(params[:id].to_s)
  slot_start = api_hold_slot_param!(ticket, api_json_body!)

  google_access = api_google_token!

  token = ticket["token"]
  result = hold_service(google_access).remove(token: token, slot_start: slot_start)
  api_error!(409, "invalid_state", "この仮押さえは操作できる状態ではありません。") if result.status == :not_held

  AuditLog.record(:hold_deleted, ip: remote_addr, target: "#{audit_ticket_id(token)} via=api:#{@api_label}")
  # 個別削除はゲスト側でも Slack 通知しない（調整途中の操作。通知は仮押さえ・決定・全取りやめの粒度）。
  remaining = TicketStore.find(token)
  # 削除できなかった [仮ブロック] は候補からは外れてカレンダーに残るため、件数を応答で伝える
  # （決定・全取りやめと同じ扱い。残骸は件名の prefix で手動掃除できる）。
  api_json("id" => audit_ticket_id(token), "status" => TicketStore.status(remaining),
           "slots" => api_hold_slots(remaining["holds"]), "failed_deletes" => result.failed_deletes)
end

# 仮押さえをすべて取りやめてチケットを終了する（held → cancelled・[仮ブロック] も全件削除）。
post "/api/v1/holds/:id/cancel" do
  ticket = api_held_ticket!(params[:id].to_s)

  google_access = api_google_token!

  token = ticket["token"]
  result = hold_service(google_access).cancel(token: token)
  api_error!(409, "invalid_state", "この仮押さえは取りやめられる状態ではありません。") if result.status == :not_held

  AuditLog.record(:hold_cancelled, ip: remote_addr, target: "#{audit_ticket_id(token)} via=api:#{@api_label}")
  notify_hold_cancelled(holds: ticket["holds"], requester: ticket["requester"], title: ticket["title"],
                        via: @api_label)
  api_json("id" => audit_ticket_id(token), "status" => "cancelled", "failed_deletes" => result.failed_deletes)
end
