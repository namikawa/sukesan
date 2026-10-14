# frozen_string_literal: true

# 子プロセスの初期化前から有効にし、隔離が壊れても実データに触れる前に止める。
module ProtectedFileGuard
  REPOSITORY = File.expand_path("../..", __dir__)
  DIRECTORIES = %w[data log].map { |name| File.join(REPOSITORY, name) }.freeze

  def self.check!(paths)
    paths.flatten.each do |path|
      next unless path.is_a?(String)

      expanded = File.expand_path(path)
      next unless File.basename(expanded).start_with?(".env") ||
                  DIRECTORIES.any? { |dir| expanded == dir || expanded.start_with?("#{dir}/") }

      raise SecurityError, "テストが保護対象ファイルへアクセスしました"
    end
  end

  def self.wrap(target, methods)
    guard = Module.new
    methods.each do |name|
      guard.define_method(name) do |*args, **kwargs, &block|
        ProtectedFileGuard.check!(args)
        super(*args, **kwargs, &block)
      end
    end
    target.singleton_class.prepend(guard)
  end
end

require "fileutils"
ProtectedFileGuard.wrap(File, %i[open read binread write binwrite exist? file? directory? owned? chmod rename
                                 delete unlink stat lstat])
ProtectedFileGuard.wrap(Dir, %i[mkdir glob entries children exist?])
ProtectedFileGuard.wrap(FileUtils, %i[mkdir_p rm_rf rm_f remove_entry chmod])
