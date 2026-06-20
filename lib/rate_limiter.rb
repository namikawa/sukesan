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

  # 記録をすべて消去する（主にテストでの状態リセット用）。
  def reset!
    @mutex.synchronize { @hits.clear }
  end
end
