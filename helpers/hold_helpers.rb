# frozen_string_literal: true

require "rack/utils"

# 複数カレンダー仮押さえ（/hold 系ルート・決定画面）を支えるヘルパ。
module HoldHelpers
  # セッションに保持する holder_key の上限。仮押さえのたびに token => holder_key が増えるため、
  # 上限を超えたら最も古いエントリから捨てる（FIFO）。セッションは暗号化 Cookie（実用上限 約 4KB）に
  # 載るため、無制限に貯めると復元データ（form_restore）と合わせて Cookie 溢れ＝セッション全損になり得る。
  MAX_HOLDER_KEYS = 10

  # エラー時の入力復元データ（form_restore）の JSON サイズ上限（バイト）。これを超える場合は保存しない。
  # 逆算の根拠: 暗号化 Cookie の実用上限 約 4096B。base64 化で約 1.33 倍に膨らむため、暗号化前 JSON は
  # 約 3000B が上限。復元データ以外の最悪ケース（holder_keys 10 件で 約 900B ＋ CSRF/flash/admin_at 等で
  # 約 600B ＝ 約 1500B）を差し引いた残り（約 1500B）を復元データの上限とする。超える入力（最大長の参加者
  # 2000B ＋ URL 2048B 等）は、中途半端に切り詰めるより「復元しない」方が挙動が予測可能なため丸ごと捨てる。
  MAX_FORM_RESTORE_BYTES = 1500

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
    keys = (session[:holder_keys] || {}).merge(token => holder_key)
    # 上限超過分は最も古いエントリ（挿入順の先頭）から捨てる。捨てられたホルダーは以後の破壊的操作が
    # できなくなるが、Cookie 溢れによるセッション全損（全ホルダー消失）よりは影響が限定的。
    keys = keys.to_a.last(MAX_HOLDER_KEYS).to_h if keys.size > MAX_HOLDER_KEYS
    session[:holder_keys] = keys
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
    # 復元データが大きすぎる場合（最大長の参加者・URL 等）は保存しない。Cookie 溢れでセッション全損
    # （flash_alert・holder_keys まで失う）になるくらいなら、入力復元だけ諦める方が予測可能。
    session[:form_restore] = @form_restore if @form_restore && form_restore_small_enough?(@form_restore)
    redirect "/t/#{token}#{search_query_suffix}"
  end

  # 復元データが Cookie 予算（MAX_FORM_RESTORE_BYTES）に収まるか。JSON 化したバイト数で判定する。
  def form_restore_small_enough?(data)
    JSON.generate(data).bytesize <= MAX_FORM_RESTORE_BYTES
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
