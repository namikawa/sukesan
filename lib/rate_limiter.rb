# frozen_string_literal: true

# 単純なメモリ上のレート制限。キー（例: IP アドレス）ごとに、
# window_seconds 秒のスライディングウィンドウ内で max 回までを許可する。
# Puma のマルチスレッドから安全に使えるよう Mutex で保護する。
#
# キーは window ごとに最大 1 回 sweep して空・全期限切れを削除し、二度と来ない IP
# （特に IPv6 は無限に作れる）のキーが溜まり続けてメモリが単調増加するのを防ぐ。
class RateLimiter
  def initialize(max:, window_seconds:)
    @max = max
    @window = window_seconds
    @hits = {}
    @mutex = Mutex.new
    @last_sweep = nil
  end

  # 許可する場合は記録して true、上限超過なら false を返す。
  def allow?(key, now: Time.now)
    @mutex.synchronize do
      sweep(now)
      times = recent(key, now)
      return false if times.size >= @max

      @hits[key] = times << now
      true
    end
  end

  # 記録はせず、現在その key が上限に達している（これ以上は不許可）かどうかだけを返す。
  # 失敗のみカウントしたい用途で、記録（record）と判定（exceeded?）を分けて使う。
  def exceeded?(key, now: Time.now)
    @mutex.synchronize do
      sweep(now)
      recent(key, now).size >= @max
    end
  end

  # 1 回分の試行を記録する（例: ログイン失敗時のみ呼ぶ）。
  def record(key, now: Time.now)
    @mutex.synchronize do
      sweep(now)
      @hits[key] = recent(key, now) << now
    end
  end

  # 記録をすべて消去する（主にテストでの状態リセット用）。
  def reset!
    @mutex.synchronize do
      @hits.clear
      @last_sweep = nil
    end
  end

  private

  # 期限内のタイムスタンプだけを新しい配列で返す（空キーを作らないようハッシュには触れない）。
  def recent(key, now)
    (@hits[key] || []).reject { |t| now - t > @window }
  end

  # 期限切れを各キーから除き、空になったキーごと削除する。負荷を抑えるため window 経過時のみ走らせる。
  def sweep(now)
    return if @last_sweep && now - @last_sweep < @window

    @hits.delete_if do |_key, times|
      times.reject! { |t| now - t > @window }
      times.empty?
    end
    @last_sweep = now
  end
end
