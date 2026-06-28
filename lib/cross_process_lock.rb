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
      dir = File.dirname(path)
      # ロック用ディレクトリも保存データと同じ 0700 に寄せる。先に既定 umask で作られていた場合に備え、
      # 所有しているときは明示的に chmod する（mkdir_p は既存ディレクトリの mode を変更しないため）。
      # 特殊な mount・権限環境で chmod が拒否されても致命的ではないので、その場合は mkdir_p の結果に委ねる。
      FileUtils.mkdir_p(dir, mode: 0o700)
      begin
        File.chmod(0o700, dir) if File.owned?(dir)
      rescue Errno::EPERM, Errno::EACCES
        # 所有者でない・権限不足。flock 自体は機能するため続行する。
      end
      File.open(path, File::CREAT | File::RDWR, 0o600) do |file|
        file.flock(File::LOCK_EX)
        yield
      end
    end
  end
end
