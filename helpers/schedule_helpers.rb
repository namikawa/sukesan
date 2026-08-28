# frozen_string_literal: true

require "uri"

# スケジュール調整フォームの入力解釈・既定値まわりのヘルパ。
module ScheduleHelpers
  # メールアドレス判定は標準の正規表現を使う（アンカー付きで制御文字・空白・不正形式を拒否）。
  EMAIL_PATTERN = URI::MailTo::EMAIL_REGEXP

  # ビデオ会議 URL の最大長（DoS・誤入力対策）。検証ルール（valid_http_url?）と一体で持つ。
  MAX_URL_LENGTH = 2048

  # 参加者の最大件数（DoS・誤入力対策）。検証ロジック（optional_event_error）と一体で持つ。
  MAX_ATTENDEES = 50

  # 公開フォームからの状態変更 POST（登録・仮押さえ・決定・削除・全取りやめ）のスパム対策。
  # IP ごとの上限を超えたら 429 で中断する。SCHEDULE_LIMITER は app.rb の定数を参照する
  # （HoldHelpers が BOOKING_LOCK / EVENT_ID_KEY を参照しているのと同じ流儀）。
  def guard_schedule_rate_limit!
    halt 429, "リクエストが多すぎます。しばらく時間をおいてからお試しください。" unless SCHEDULE_LIMITER.allow?(client_ip)
  end

  # 登録（/schedule）・仮押さえ作成（/hold）に共通の入口ガード。ワンタイム URL が使える状態か、
  # Google 連携が生きているかを順に確認し、満たさなければ元画面へ警告付きで戻す。
  # 呼び出し側は先に @form_restore を設定しておくこと（redirect_with_alert! が入力復元に使うため）。
  def guard_usable_ticket!(token)
    ticket = TicketStore.find(token)
    redirect_with_alert!(token, "この URL は無効か、期限切れです。管理者に新しい URL の発行を依頼してください。") unless TicketStore.active?(ticket)
    redirect_with_alert!(token, "Google の連携が必要です。管理者にお問い合わせください。") unless google_connected?
  end

  # 空き時間検索サービスを、管理者の Google カレンダーに接続して組み立てる。
  # token は呼び出し側で取得済みのものを渡す（refresh 失敗＝nil のガードは呼び出し側の責務）。
  def availability_search(settings, token)
    AvailabilitySearch.new(settings: settings, calendar_client: GoogleCalendarClient.new(token))
  end

  # 予約成立時にチケットへ保存する属性（TicketStore.use! に渡す）。任意項目（参加者）は入力があるときだけ持たせる。
  # 会議 URL（video_url / meet_link）はチケットに永続化しない（漏えい URL からの再露出を避ける）。
  # 何を残すかはゲスト経路と API 経路で共通の決めごとなので、ここに 1 か所だけ置く。
  def booking_ticket_attrs(requester:, title:, starts_at:, ends_at:, attendees:)
    attrs = { "requester" => requester, "title" => title,
              "slot_start" => starts_at.iso8601, "slot_end" => ends_at.iso8601 }
    attrs["attendees"] = attendees unless attendees.empty?
    attrs
  end

  # 予約サービスを、管理者の Google カレンダーに接続して組み立てる（HoldHelpers#hold_service と対称）。
  def booking_service(google_access)
    BookingService.new(
      lock: BOOKING_LOCK,
      availability: availability_search(SettingsStore.load, google_access),
      calendar_client: GoogleCalendarClient.new(google_access),
      event_id_key: EVENT_ID_KEY
    )
  end

  # テキストエリアの入力を参加者メールアドレスの配列に分解する。
  # 改行・カンマ・スペース（タブ等の空白）を区切りとして扱い、空要素と重複を除く。
  def parse_attendees(raw)
    raw.to_s.split(/[\s,]+/).reject(&:empty?).uniq
  end

  # 任意項目（参加者・ビデオ会議 URL・Meet 発行）の検証。最初に見つかったエラー文言を返し、
  # 問題なければ nil。予約（/schedule）と決定（/hold/confirm）で同一の検証・文言を使う
  # （エラーの伝え方＝halt か redirect かは呼び出し側の責務）。
  def optional_event_error(attendees:, video_url:, request_meet:)
    return "参加者は最大 #{MAX_ATTENDEES} 件までです。" if attendees.size > MAX_ATTENDEES
    return "参加者メールアドレスの形式が正しくありません。" unless attendees.all? { |email| valid_email?(email) }
    return nil if video_url.empty? # ビデオ会議 URL 未指定なら以降の URL 検証は不要

    return "ビデオ会議 URL の形式が正しくありません（http/https の URL）。" unless valid_http_url?(video_url)
    return "ビデオ会議 URL の指定と Google Meet の発行は同時に指定できません。" if request_meet

    nil
  end

  # 主催者（管理者自身）を参加者に含める。連携時に取得・保存したメールを先頭に足し、
  # 空要素と（大文字小文字を無視した）重複を除く。取得できていなければ依頼者入力分のみ。
  def attendees_with_admin(attendees)
    ([google_admin_email.to_s] + attendees).reject(&:empty?).uniq(&:downcase)
  end

  def valid_email?(value)
    value.match?(EMAIL_PATTERN)
  end

  def valid_http_url?(value)
    value.length <= MAX_URL_LENGTH && value.match?(%r{\Ahttps?://[^\s]+\z})
  end

  # 翌日以降で、調整可能な営業日（曜日一致 かつ 祝日でない）に該当する最初の日付。
  # 曜日が未設定なら無限ループを避けるため単純に翌日を返す。
  def next_business_day(business_days)
    date = Date.today + 1
    return date if business_days.empty?

    date += 1 until AvailabilitySearch.business_day?(date, business_days)
    date
  end

  # "開始ISO8601/終了ISO8601" を [Time, Time] に厳格パースする。不正なら [nil, nil]。
  def parse_slot(raw)
    starts_iso, ends_iso = raw.to_s.split("/", 2)
    return [nil, nil] if starts_iso.nil? || ends_iso.nil?

    [Time.iso8601(starts_iso), Time.iso8601(ends_iso)]
  rescue ArgumentError
    [nil, nil]
  end
end
