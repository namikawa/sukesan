# frozen_string_literal: true

require "time"

# Google / Outlook の両方のイベントを同じ形に正規化する値オブジェクト。
#
# match_key は「件名 + 開始 + 終了」で2つのカレンダーのイベントが同一かどうかを
# 判定するためのキー。各カレンダーでイベント ID は異なるため、内容で突き合わせる。
Event = Struct.new(
  :source, :external_id, :title, :starts_at, :ends_at, :location, :all_day, :description,
  keyword_init: true
) do
  def normalized_title
    title.to_s.strip.downcase
  end

  def match_key
    if all_day
      [normalized_title, date_key(starts_at), "all-day"].join("|")
    else
      [normalized_title, time_key(starts_at), time_key(ends_at)].join("|")
    end
  end

  def date_key(time)
    time&.utc&.strftime("%F")
  end

  def time_key(time)
    time&.utc&.iso8601
  end

  # セッションへ保存できるよう Time は ISO8601 文字列に変換する。
  def to_h
    {
      source: source,
      external_id: external_id,
      title: title,
      starts_at: starts_at&.iso8601,
      ends_at: ends_at&.iso8601,
      location: location,
      all_day: all_day,
      description: description
    }
  end

  def self.from_h(hash)
    h = hash.transform_keys(&:to_sym)
    new(
      source: h[:source],
      external_id: h[:external_id],
      title: h[:title],
      starts_at: h[:starts_at] && Time.parse(h[:starts_at]),
      ends_at: h[:ends_at] && Time.parse(h[:ends_at]),
      location: h[:location],
      all_day: h[:all_day],
      description: h[:description]
    )
  end
end
