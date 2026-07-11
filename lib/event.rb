# frozen_string_literal: true

require "time"

# Google / Outlook の両方のイベントを同じ形に正規化する値オブジェクト。
#
# match_key は「件名 + 開始 + 終了」で2つのカレンダーのイベントが同一かどうかを
# 判定するためのキー。各カレンダーでイベント ID は異なるため、内容で突き合わせる。
# cancelled は Outlook 側の isCancelled（キャンセル済み）。同期候補から除外する判定に使う。
Event = Struct.new(
  :source, :external_id, :title, :starts_at, :ends_at, :location, :all_day, :description, :cancelled,
  keyword_init: true
) do
  # 件名比較用の正規化。手動転送で付く「Fw:」（Fwd: 含む・繰り返し可）を先頭から除去し、
  # Google 側「Fw: 会議」と Outlook 側「会議」を同一とみなせるようにする。
  def normalized_title
    title.to_s.strip.sub(/\A(?:fwd?:\s*)+/i, "").strip.downcase
  end

  def match_key
    if all_day
      [normalized_title, date_key(starts_at), "all-day"].join("|")
    else
      [normalized_title, time_key(starts_at), time_key(ends_at)].join("|")
    end
  end

  # 終日予定の日付。各カレンダーは終日の開始をそれぞれのタイムゾーンの深夜 0 時として返すため
  # （Google=ローカル深夜・Outlook=UTC 深夜）、UTC へ寄せず「その Time が指す日付」をそのまま使う。
  # UTC 変換すると Google 側（JST 深夜 0 時）が前日にずれ、同一日の終日予定が突き合わせで一致しなくなる。
  def date_key(time)
    time&.strftime("%F")
  end

  def time_key(time)
    time&.utc&.iso8601
  end
end
