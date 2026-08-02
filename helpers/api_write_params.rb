# frozen_string_literal: true

require "time"

# 書き込み系 API（/api/v1 の POST）の入力（JSON ボディの各項目・Idempotency-Key ヘッダ）を検証し、
# Ruby の値へ変換するヘルパ。不正な入力は 400 invalid_params で中断する（ApiHelpers#api_error!）。
#
# 検証の基準はゲスト画面（POST /schedule・/hold）と同一だが、入力の型は JSON に合わせる
# （チェックボックスの "1" ではなく boolean、改行区切りテキストではなく配列）。
# 「その枠が予約できるか」（空き・営業日・過去）は BookingService / HoldService がロック内で
# 再検証するため、ここでは形式の検証だけを行う。
module ApiWriteParams
  # Idempotency-Key ヘッダの最大長（DoS・誤入力対策）。
  MAX_IDEMPOTENCY_KEY_LENGTH = 128

  # 予約する時間帯（{"starts_at": …, "ends_at": …}）を [Time, Time] に変換する。
  def api_slot_param!(body)
    slot = body["slot"]
    api_error!(400, "invalid_params", "slot は starts_at / ends_at を持つオブジェクトです。") unless slot.is_a?(Hash)

    [api_time_param!(slot, "starts_at"), api_time_param!(slot, "ends_at")]
  end

  # slot の日時（ISO8601・オフセット付き）。欠落・不正形式は 400。
  # prefix はエラー文言で項目を指す名前（単一の slot / 配列の slots[] を区別する）。
  def api_time_param!(slot, name, prefix: "slot")
    Time.iso8601(slot[name].to_s)
  rescue ArgumentError
    api_error!(400, "invalid_params", "#{prefix}.#{name} は ISO8601 形式の日時で指定してください（必須）。")
  end

  # 仮押さえする時間帯の配列を [[Time, Time], ...] に変換する。件数（1〜MAX_HOLDS）と相互の重複は
  # ゲストの仮押さえ（POST /hold）と同一基準で弾く。「その枠を確保できるか」（空き・営業日・過去）は
  # HoldService がロック内で再検証する。
  def api_hold_slots_param!(body)
    value = body["slots"]
    unless value.is_a?(Array) && !value.empty? && value.size <= HoldService::MAX_HOLDS
      api_error!(400, "invalid_params", "slots は 1〜#{HoldService::MAX_HOLDS} 件の時間帯の配列で指定してください。")
    end

    slots = value.map { |slot| api_hold_slot_times!(slot) }
    api_error!(400, "invalid_params", "slots の時間帯が重複しています。重ならないように指定してください。") if overlapping_slots?(slots)

    slots
  end

  # slots の 1 要素（{"starts_at", "ends_at"}）を [Time, Time] に変換する。
  def api_hold_slot_times!(slot)
    api_error!(400, "invalid_params", "slots の各要素は starts_at / ends_at を持つオブジェクトです。") unless slot.is_a?(Hash)

    [api_time_param!(slot, "starts_at", prefix: "slots[]"), api_time_param!(slot, "ends_at", prefix: "slots[]")]
  end

  # 決定・個別削除の対象スロット（仮押さえ候補の開始時刻）。文字列でない・空は 400 で、
  # チケットに保存された候補に無い値は存在しない対象として 404
  # （イベント ID はクライアントから受け取らず、保存済み候補の開始時刻だけをキーにする既存原則）。
  def api_hold_slot_param!(ticket, body)
    slot_start = body["slot_starts_at"]
    unless slot_start.is_a?(String) && !slot_start.empty?
      api_error!(400, "invalid_params", "slot_starts_at は仮押さえ候補の開始時刻（ISO8601 文字列）で指定してください（必須）。")
    end
    halt 404 unless Array(ticket["holds"]).any? { |hold| hold["slot_start"] == slot_start }

    slot_start
  end

  # 必須テキスト（依頼者名・予定名）。空・文字列以外・上限超過は 400（上限はゲストと同じ）。
  def api_text_param!(body, name)
    value = body[name]
    text = value.is_a?(String) ? value.strip : ""
    return text unless text.empty? || text.length > MAX_TEXT_LENGTH

    api_error!(400, "invalid_params", "#{name} は #{MAX_TEXT_LENGTH} 文字以内の文字列で指定してください（必須）。")
  end

  # 任意テキスト（ビデオ会議 URL など）。省略・null は ""、文字列以外の型は 400。
  def api_optional_text_param!(body, name)
    value = body[name]
    return "" if value.nil?
    return value.strip if value.is_a?(String)

    api_error!(400, "invalid_params", "#{name} は文字列で指定してください。")
  end

  # 任意の真偽値。省略・null は false。JSON の boolean 以外（"1" や "true" などの文字列）は 400
  # （クライアント提示の文字列をそのまま Google へ流さない既存方針）。
  def api_boolean_param!(body, name)
    value = body[name]
    return false if value.nil?
    return value if [true, false].include?(value)

    api_error!(400, "invalid_params", "#{name} は true / false で指定してください。")
  end

  # 参加者メールアドレス（任意）。文字列の配列で受け、空要素と重複を除いて返す。
  # 件数・形式の検証は呼び出し側で optional_event_error に通す（ゲストと同一基準・同一文言）。
  def api_attendees_param!(body)
    value = body["attendees"]
    return [] if value.nil?
    return value.map(&:strip).reject(&:empty?).uniq if value.is_a?(Array) && value.all?(String)

    api_error!(400, "invalid_params", "attendees はメールアドレス（文字列）の配列で指定してください。")
  end

  # 冪等キー（任意ヘッダ Idempotency-Key）。未指定・空は nil、上限超過は 400。
  # 返す値は認証済み API キーのラベルでスコープする（"<ラベル>:<キー>"）。別システムが偶然同じ
  # キー文字列を使っても他システムの予約のリプレイ応答を受け取らないよう、保存・照合・event id の
  # 導出はすべてこのスコープ済みの値で行う。
  def api_idempotency_key!
    key = request.env["HTTP_IDEMPOTENCY_KEY"].to_s.strip
    return nil if key.empty?
    return "#{@api_label}:#{key}" if key.length <= MAX_IDEMPOTENCY_KEY_LENGTH

    api_error!(400, "invalid_params", "Idempotency-Key は #{MAX_IDEMPOTENCY_KEY_LENGTH} 文字以内で指定してください。")
  end
end
