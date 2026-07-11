# frozen_string_literal: true

# 2つのカレンダーのイベントを突き合わせ、Outlook 側にのみ存在するイベントを抽出する。
module EventDiffer
  module_function

  def outlook_only(google_events:, outlook_events:)
    # Google 側の突き合わせキーを「件数」で持つ（マルチセット）。同一件名・同一時刻の予定が
    # Outlook に複数・Google に一部だけある場合に、Google の件数分だけを「既存」として消し込み、
    # 余った分を同期候補として残す（Boolean 判定では 2 件とも既存扱いになり取りこぼす）。
    # キャンセル済み（isCancelled）の Outlook イベントは同期対象外。
    google_counts = google_events.map(&:match_key).tally
    outlook_events.reject do |event|
      next true if event.cancelled

      key = event.match_key
      if google_counts.fetch(key, 0).positive?
        google_counts[key] -= 1 # Google 側の 1 件を消し込む（これ以降の同一キーは同期候補に残る）
        true
      else
        false
      end
    end
  end
end
