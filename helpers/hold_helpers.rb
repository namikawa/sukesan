# frozen_string_literal: true

require "rack/utils"

# 複数カレンダー仮押さえ（/hold 系ルート・決定画面）を支えるヘルパ。
module HoldHelpers
  # 仮押さえを実行したブラウザ（ホルダー）か。セッションの holder_key とチケットの保存値を
  # 定数時間比較で照合する。破壊的操作（決定・個別削除・全取りやめ）はホルダーのみに許可し、
  # URL だけを知る第三者は候補の閲覧のみ可能とする（設計上の第二要素。Cookie は URL と別経路）。
  def holder_of?(ticket)
    key = session[:holder_keys]&.[](ticket["token"])
    !key.nil? && !ticket["holder_key"].nil? && Rack::Utils.secure_compare(key, ticket["holder_key"])
  end

  # 仮押さえ実行時に holder_key をセッションへ記録する（ネストした Hash は再代入で確実に永続化する）。
  # Cookie 期限の延長は before フィルタが担うが、フィルタはリクエスト開始時点の holder_keys を見るため、
  # 記録した当のレスポンスにも効くようここでも延長する。
  def remember_holder!(token, holder_key)
    session[:holder_keys] = (session[:holder_keys] || {}).merge(token => holder_key)
    session.options[:expire_after] = TicketStatus::HOLD_TTL_SECONDS
  end

  # チケットが終端状態（決定・取りやめ・期限切れ・無効化）になったら holder_key を掃除する。
  # holder_keys が空になれば Cookie 期限の延長（before フィルタ）も自然に止まる。
  def forget_holder!(token)
    keys = session[:holder_keys]
    return if keys.nil? || !keys.key?(token)

    rest = keys.except(token)
    rest.empty? ? session.delete(:holder_keys) : session[:holder_keys] = rest
  end

  # 複数選択（checkbox）の slot 値を [[Time, Time], ...] に厳格パースする（不正要素は [nil, nil]）。
  def parse_hold_slots(raw)
    Array(raw).map { |value| parse_slot(value) }
  end

  # 選択スロット同士に時間帯の重なりがあるか（同一時間帯の二重ブロック防止）。
  def overlapping_slots?(slots)
    slots.combination(2).any? { |(s1, e1), (s2, e2)| s1 < e2 && s2 < e1 }
  end

  # 入力・状態エラーをエラーページでなく、元画面上部の警告通知（flash_alert）で伝える
  # （redirect は処理をその場で中断する）。ルート側で @form_restore が設定されていれば、
  # 入力値も一時保存して復元させる（1 回で消費）。
  def redirect_with_alert!(token, message)
    session[:flash_alert] = message
    session[:form_restore] = @form_restore if @form_restore
    redirect "/t/#{token}#{search_query_suffix}"
  end

  # 仮押さえフォームが hidden で引き回す検索条件（あれば ?start_date=... を付け直し、
  # 候補一覧の表示状態を保つ）。
  def search_query_suffix
    query = { start_date: params[:start_date].to_s, end_date: params[:end_date].to_s,
              duration: params[:duration].to_s }.reject { |_, value| value.empty? }
    query.empty? ? "" : "?#{Rack::Utils.build_query(query)}"
  end

  # 仮押さえサービスを、管理者の Google カレンダーに接続して組み立てる。
  def hold_service(google_access)
    HoldService.new(
      lock: BOOKING_LOCK,
      availability: availability_search(SettingsStore.load, google_access),
      calendar_client: GoogleCalendarClient.new(google_access),
      event_id_key: EVENT_ID_KEY
    )
  end

  # 決定・削除の結果に応じた注意書き（部分失敗の通知）を flash 文言へ足す。
  def hold_result_notes(result)
    notes = +""
    notes << " ※カレンダーの件名更新に失敗しました（[仮ブロック] のままになっています）。" if result.patch_failed
    notes << " ※#{result.failed_deletes} 件の仮押さえイベントを削除できませんでした。" if result.failed_deletes.to_i.positive?
    notes
  end

  # チケットに残っていた仮押さえイベントを削除する（管理者の無効化＝kill switch 用）。
  # 削除できなかった件数を返す（連携トークンが使えない場合は全件失敗扱い）。
  def delete_hold_events(holds)
    return 0 if holds.empty?

    google_access = google_token
    return holds.size if google_access.nil?

    client = GoogleCalendarClient.new(google_access)
    holds.count do |hold|
      client.delete_event(hold["event_id"])
      false
    rescue StandardError => e
      warn "[HoldHelpers] 仮押さえイベントの削除失敗: #{e.class}"
      true
    end
  end
end
