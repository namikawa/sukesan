# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "cross_process_lock"

RSpec.describe CrossProcessLock do
  it "既定 umask で緩く作られた既存ディレクトリも 0700 に直す" do
    Dir.mktmpdir do |base|
      dir = File.join(base, "store")
      FileUtils.mkdir_p(dir, mode: 0o755) # 先に緩い権限で作られた状態を再現
      lock = described_class.new(File.join(dir, ".lock"))

      lock.synchronize { :noop }

      expect(File.stat(dir).mode & 0o777).to eq(0o700)
    end
  end

  it "ロックファイルは 0600 で作られる" do
    Dir.mktmpdir do |base|
      path = File.join(base, "sub", ".lock")
      described_class.new(path).synchronize { :noop }
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end
  end
end
