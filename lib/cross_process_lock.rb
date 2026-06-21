# frozen_string_literal: true

require "fileutils"

# プロセス内スレッドと、同一ホスト上の別プロセスの両方を直列化する排他ロック。
#
# プロセス内は Mutex、プロセス間はロックファイルの flock(LOCK_EX) で保護する。
# flock は同一ホストでのみ有効（NFS や複数ホスト分散では保証されない）点に注意。
class CrossProcessLock
  # path_or_proc: ロックファイルのパス（String）か、呼ぶとパスを返す callable。
  # テストなどで保存先（ディレクトリ）が動的に変わる場合は callable を渡す。
  def initialize(path_or_proc)
    @path_or_proc = path_or_proc
    @mutex = Mutex.new
  end

  def synchronize
    @mutex.synchronize do
      path = @path_or_proc.respond_to?(:call) ? @path_or_proc.call : @path_or_proc
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::CREAT | File::RDWR, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      end
    end
  end
end
