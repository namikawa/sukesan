# frozen_string_literal: true

# 単純なメモリ上のレート制限。キー（例: IP アドレス）ごとに、
# window_seconds 秒のスライディングウィンドウ内で max 回までを許可する。
# Puma のマルチスレッドから安全に使えるよう Mutex で保護する。
class RateLimiter
  def initialize(max:, window_seconds:)
    @max = max
    @window = window_seconds
    @hits = Hash.new { |hash, key| hash[key] = [] }
    @mutex = Mutex.new
  end

  # 許可する場合は記録して true、上限超過なら false を返す。
  def allow?(key, now: Time.now)
    @mutex.synchronize do
      times = @hits[key]
      times.reject! { |t| now - t > @window }
      return false if times.size >= @max

      times << now
      true
    end
  end

  # 記録はせず、現在その key が上限に達している（これ以上は不許可）かどうかだけを返す。
  # 失敗のみカウントしたい用途で、記録（record）と判定（exceeded?）を分けて使う。
  def exceeded?(key, now: Time.now)
    @mutex.synchronize do
      times = @hits[key]
      times.reject! { |t| now - t > @window }
      times.size >= @max
    end
  end

  # 1 回分の試行を記録する（例: ログイン失敗時のみ呼ぶ）。
  def record(key, now: Time.now)
    @mutex.synchronize do
      times = @hits[key]
      times.reject! { |t| now - t > @window }
      times << now
    end
  end

  # 記録をすべて消去する（主にテストでの状態リセット用）。
  def reset!
    @mutex.synchronize { @hits.clear }
  end
end
