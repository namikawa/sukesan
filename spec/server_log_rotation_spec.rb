# frozen_string_literal: true

require "tmpdir"
require "timeout"

RSpec.describe ServerLogRotation do
  def with_log
    Dir.mktmpdir("server-log-rotation") do |dir|
      path = File.join(dir, "server.log")
      File.write(path, "existing\n")
      File.open(path, "a") do |stdout|
        File.open(path, "a") do |stderr|
          yield path, stdout, stderr
        end
      end
    end
  end

  it "起動時に週をまたいだ既存ログを保存し、両ストリームを新ファイルへ切り替える" do
    with_log do |path, stdout, stderr|
      old = Time.now - (14 * 86_400)
      File.utime(old, old, path)
      rotation = described_class.new(path, stdout: stdout, stderr: stderr)
      thread = rotation.start
      thread.kill.join
      expect(stdout.close_on_exec?).to be(true)
      expect(stderr.close_on_exec?).to be(true)

      stdout.write("stdout-after\n")
      stderr.write("stderr-after\n")
      rotated = Dir.glob("#{path}.*")
      expect(rotated.size).to eq(1)
      expect(File.read(rotated.first)).to include("existing\n")
      expect(File.read(path)).to include("stdout-after\n", "stderr-after\n")
      expect(File.read(rotated.first)).not_to include("stdout-after", "stderr-after")
    end
  end

  it "週境界の切替中も並行出力を旧・新ファイルのいずれかへすべて残す" do
    with_log do |path, stdout, stderr|
      old = Time.now - (14 * 86_400)
      File.utime(old, old, path)
      rotation = described_class.new(path, stdout: stdout, stderr: stderr)
      writers = [stdout, stderr].each_with_index.map do |io, stream|
        Thread.new { 100.times { |i| io.write("marker-#{stream}-#{i}\n") } }
      end
      rotation.check!
      writers.each(&:join)

      contents = ([path] + Dir.glob("#{path}.*")).map { |file| File.read(file) }.join
      2.times do |stream|
        100.times { |i| expect(contents.scan("marker-#{stream}-#{i}\n").size).to eq(1) }
      end
    end
  end

  it "実際の FD 1/2 でも並行出力を欠落させずに切り替える" do
    Dir.mktmpdir("server-log-rotation") do |dir|
      path = File.join(dir, "server.log")
      File.write(path, "existing\n")
      old = Time.now - (14 * 86_400)
      File.utime(old, old, path)

      pid = fork do
        $stdout.reopen(path, "a")
        $stderr.reopen(path, "a")
        rotation = described_class.new(path)
        writers = [$stdout, $stderr].each_with_index.map do |io, stream|
          Thread.new { 200.times { |i| io.write("child-#{stream}-#{i}\n") } }
        end
        rotation.check!
        writers.each(&:join)
        exit! 1 if $stdout.close_on_exec? || $stderr.close_on_exec?
        exit! 0
      end
      _, status = Process.waitpid2(pid)
      expect(status.exitstatus).to eq(0)

      contents = ([path] + Dir.glob("#{path}.*")).map { |file| File.read(file) }.join
      2.times do |stream|
        200.times { |i| expect(contents.scan("child-#{stream}-#{i}\n").size).to eq(1) }
      end
    end
  end

  it "重複したチェックを直列化する" do
    with_log do |path, stdout, stderr|
      rotation = described_class.new(path, stdout: stdout, stderr: stderr)
      device = rotation.instance_variable_get(:@device)
      active = 0
      maximum = 0
      allow(device).to receive(:write) do
        active += 1
        maximum = [maximum, active].max
        sleep 0.01
        active -= 1
      end

      [Thread.new { rotation.check! }, Thread.new { rotation.check! }].each(&:join)
      expect(maximum).to eq(1)
    end
  end

  it "周期チェックが一時的に失敗してもログに残して次周期に再試行する" do
    with_log do |path, stdout, stderr|
      rotation = described_class.new(path, stdout: stdout, stderr: stderr, interval: 0.001)
      original_check = rotation.method(:check!)
      calls = 0
      retried = Queue.new
      rotation.define_singleton_method(:check!) do
        calls += 1
        raise IOError, "temporary" if calls == 2

        original_check.call
        retried << true if calls == 3
      end

      thread = rotation.start
      begin
        Timeout.timeout(1) { retried.pop }
        expect(File.read(path)).to include("[ServerLogRotation] 切替失敗: IOError")
      ensure
        thread.kill.join
      end
    end
  end

  it "rename 後にログデバイスが閉じて残っても新ファイルを作り直す" do
    with_log do |path, stdout, stderr|
      rotation = described_class.new(path, stdout: stdout, stderr: stderr)
      device = rotation.instance_variable_get(:@device)
      allow(device).to receive(:write) do
        File.rename(path, "#{path}.old")
        device.dev.close
      end

      rotation.check!
      stdout.write("recovered-stdout\n")
      stderr.write("recovered-stderr\n")
      expect(File.read("#{path}.old")).to include("existing\n")
      expect(File.read(path)).to include("recovered-stdout\n", "recovered-stderr\n")
    end
  end

  it "同じ週の再起動では既存ログへ追記する" do
    with_log do |path, stdout, stderr|
      first = described_class.new(path, stdout: stdout, stderr: stderr)
      first.check!
      stdout.write("before-restart\n")
      second = described_class.new(path, stdout: stdout, stderr: stderr)
      second.check!
      stderr.write("after-restart\n")

      expect(Dir.glob("#{path}.*")).to be_empty
      expect(File.read(path)).to include("existing\n", "before-restart\n", "after-restart\n")
    end
  end

  it "stdout または stderr が pipe の場合は無効にする" do
    with_log do |path, stdout, stderr|
      reader, writer = IO.pipe
      begin
        expect(described_class.new(path, stdout: writer, stderr: stderr)).not_to be_enabled
        expect(described_class.new(path, stdout: stdout, stderr: writer)).not_to be_enabled
      ensure
        reader.close
        writer.close
      end
    end
  end
end
