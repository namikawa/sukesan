# frozen_string_literal: true

require "logger"
require "fiddle"

# ファイルへリダイレクトされたサーバの stdout/stderr を週次で切り替える。
# Logger::LogDevice が旧ファイルを rename して新ファイルを開いた後、両ストリームを
# 新ファイルへ接続し直す。切替中に旧 FD へ書かれた行も旧ファイルに残る。
class ServerLogRotation
  INTERVAL_SECONDS = 60
  DUP2 = Fiddle::Function.new(Fiddle::Handle::DEFAULT["dup2"], [Fiddle::TYPE_INT, Fiddle::TYPE_INT], Fiddle::TYPE_INT,
                              need_gvl: true)

  def self.start(path)
    return if path.to_s.empty?

    rotation = new(path)
    rotation.start if rotation.enabled?
  end

  def initialize(path, stdout: $stdout, stderr: $stderr, interval: INTERVAL_SECONDS)
    @path = path
    @stdout = stdout
    @stderr = stderr
    @interval = interval
    @enabled = same_regular_file?(stdout, path) && same_regular_file?(stderr, path)
    return unless @enabled

    @mutex = Mutex.new
    @device = Logger::LogDevice.new(path, shift_age: "weekly")
    @stdout.sync = true
    @stderr.sync = true
  end

  def enabled?
    @enabled
  end

  def check!
    return unless enabled?

    @mutex.synchronize do
      @stdout.flush
      @stderr.flush
      reopen_device_if_closed
      @device.write("") # 書き込みがなくても週境界を判定する
      reopen_device_if_closed
      return if same_file?(@stdout, @device.dev) && same_file?(@stderr, @device.dev)

      redirect(@stdout)
      redirect(@stderr)
    end
  end

  def start
    check! # 停止中に週が変わっていた場合も起動時に切り替える
    Thread.new do
      loop do
        sleep @interval
        begin
          check!
        rescue StandardError => e
          # 一時的なファイル操作失敗でも次の周期で再試行する。
          begin
            @stderr.puts("[ServerLogRotation] 切替失敗: #{e.class}")
          rescue StandardError
            nil # stderr 自体が使えない場合も監視スレッドは維持する
          end
        end
      end
    end
  end

  private

  def reopen_device_if_closed
    @device = Logger::LogDevice.new(@path, shift_age: "weekly") if @device.dev.closed?
  end

  def same_regular_file?(io, path)
    stat = io.stat
    target = File.stat(path)
    stat.file? && target.file? && stat.dev == target.dev && stat.ino == target.ino
  rescue IOError, SystemCallError
    false
  end

  def same_file?(left, right)
    left_stat = left.stat
    right_stat = right.stat
    left_stat.dev == right_stat.dev && left_stat.ino == right_stat.ino
  end

  def redirect(io)
    return if same_file?(io, @device.dev)

    destination = io.fileno
    close_on_exec = io.close_on_exec?
    loop do
      result = DUP2.call(@device.dev.fileno, destination)
      if result == destination
        io.close_on_exec = close_on_exec
        return
      end

      error = Fiddle.last_error
      raise SystemCallError.new("dup2", error) unless error == Errno::EINTR::Errno
    end
  end
end
