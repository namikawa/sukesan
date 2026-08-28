# frozen_string_literal: true

# 調整ツールが作る Google 予定の件名・説明の書式。
#
# 同じ書式を、ゲスト経路（POST /schedule・仮押さえの作成と決定）と API 経路（POST /api/v1/bookings・
# /api/v1/holds…）の両方から組み立てるため、副作用のない純粋関数として 1 か所に集約する
# （書き方が経路ごとに分かれると、片方だけ変わって予定の見た目が食い違う）。
# 仮押さえ固有の件名 prefix（[仮ブロック]）は HoldService の関心なので、ここには持たせない。
module EventFormat
  module_function

  # 予定の件名。「予定名 - 依頼者名 (from 調整ツール)」。
  def summary(title:, requester:)
    "#{title} - #{requester} (from 調整ツール)"
  end

  # 予定の説明。ビデオ会議 URL の指定があるときだけ 2 行目に添える。
  def description(requester:, video_url: nil)
    text = "依頼者: #{requester}"
    text += "\nビデオ会議: #{video_url}" unless video_url.to_s.empty?
    text
  end
end
