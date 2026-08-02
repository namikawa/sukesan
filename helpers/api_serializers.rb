# frozen_string_literal: true

# 他システム向け JSON API（/api/v1/…）のレスポンス整形ヘルパ。
# ドメインオブジェクト（AvailabilitySearch::Result・チケット Hash・Event 構造体）を JSON 化できる
# Hash へ変換する。認証・認可・入力検証・エラー応答は ApiHelpers が担う。
module ApiSerializers
  # 空き候補（AvailabilitySearch::Result）を API レスポンス用のハッシュに変換する。
  def api_availability(result, duration_minutes)
    {
      "duration_minutes" => duration_minutes,
      "capped" => result.capped,
      "days" => result.days.map do |date, slots|
        { "date" => date.strftime("%F"), "slots" => slots.map { |slot| api_slot(slot) } }
      end
    }
  end

  # 空き候補 1 件。lunch_warning は「その枠を取ると昼休憩の連続確保が崩れる」印（画面と同じ判定）。
  def api_slot(slot)
    {
      "starts_at" => api_time(slot.starts_at),
      "ends_at" => api_time(slot.ends_at),
      "lunch_warning" => slot.lunch
    }
  end

  # チケットを API レスポンス用のハッシュに変換する（一覧・詳細で共通のキーセット。値が無い項目は null）。
  # 生 token・ワンタイム URL・仮押さえイベント ID は含めない（漏えい経路を作らない）。
  # id は監査ログ・アクセスログと同じ HMAC 短縮 ID（呼び出し側が audit_ticket_id で導出して渡す）。
  # 保存済みの日時（created_at / slot_start など）はローカルオフセット付き ISO8601 のためそのまま返す。
  def api_ticket(ticket, id:)
    status = TicketStore.status(ticket)
    {
      "id" => id,
      "status" => status,
      "created_at" => ticket["created_at"],
      # 期限を持つのは未使用（active）と仮押さえ中（held）だけ。終端・期限切れは null。
      "expires_at" => %w[active held].include?(status) ? api_time(TicketStatus.expires_at(ticket)) : nil,
      "ttl_hours" => TicketStatus.ttl_hours(ticket),
      "requester" => ticket["requester"],
      "title" => ticket["title"],
      "slot_start" => ticket["slot_start"],
      "slot_end" => ticket["slot_end"],
      "used_at" => ticket["used_at"],
      "holds" => status == "held" ? api_holds(ticket["holds"]) : nil
    }
  end

  # 直接予約（POST /api/v1/bookings）の応答。登録した枠はチケットの保存値から組み立てる。
  # 会議 URL はチケットへ永続化しないため、meet_link に値が入るのは登録直後の応答だけ
  # （同じ Idempotency-Key のリプレイ応答では null になる）。
  def api_booking(ticket, id:, meet_link: nil)
    {
      "id" => id,
      "status" => TicketStore.status(ticket),
      "slot" => { "starts_at" => ticket["slot_start"], "ends_at" => ticket["slot_end"] },
      "meet_link" => meet_link
    }
  end

  # 仮押さえ中の候補一覧（開始時刻順）。イベント ID はクライアントへ渡さない（既存原則）。
  def api_holds(holds)
    Array(holds).sort_by { |hold| hold["slot_start"].to_s }
                .map { |hold| { "slot_start" => hold["slot_start"], "slot_end" => hold["slot_end"] } }
  end

  # 仮押さえ系の書き込み応答に載せる候補一覧。キーはリクエスト（slots）と同じ starts_at / ends_at で、
  # 値は保存済みの文字列をそのまま返す（受け取った値をそのまま slot_starts_at に使って決定・削除できる）。
  def api_hold_slots(holds)
    api_holds(holds).map { |hold| { "starts_at" => hold["slot_start"], "ends_at" => hold["slot_end"] } }
  end

  # 仮押さえの決定（POST /api/v1/holds/:id/confirm）の応答。確定した枠は直接予約と同じ形で返し、
  # 部分失敗（決定イベントの件名更新に失敗した／削除できなかった他候補の件数）を添える
  # （決定自体は成立しているため、ゲスト画面が flash で伝えている情報を API では応答に載せる）。
  def api_hold_confirmation(ticket, id:, result:)
    api_booking(ticket, id: id, meet_link: result.meet_link)
      .merge("patch_failed" => result.patch_failed, "failed_deletes" => result.failed_deletes)
  end

  # Event 構造体を API レスポンス用のハッシュに変換する。
  # 時刻は ISO8601（ローカルタイムのオフセット付き）で返す。
  def api_event(event)
    {
      "id" => event.external_id,
      "title" => event.title,
      "starts_at" => api_time(event.starts_at),
      "ends_at" => api_time(event.ends_at),
      "location" => event.location,
      "all_day" => event.all_day
    }
  end

  def api_time(time)
    time&.getlocal&.iso8601
  end
end
