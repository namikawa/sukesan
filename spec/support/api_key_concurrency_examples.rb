# frozen_string_literal: true

require "timeout"

RSpec.shared_examples "API キーの並行更新" do
  let(:key_entered) { Queue.new }
  let(:key_release) { Queue.new }
  let(:key_progress) { Queue.new }
  let(:key_threads) { [] }
  let(:key_completion_timeout) { 5 }

  def admin_browser
    browser = Rack::Test::Session.new(Rack::MockSession.new(app))
    browser.get "/settings"
    csrf = browser.last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    browser.post "/settings/login", authenticity_token: csrf, password: ENV.fetch("ADMIN_PASSWORD")
    browser.get "/settings"
    [browser, browser.last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]]
  end

  # 先行操作が最新設定を読み込んだ地点で止める。後続操作はロック待ちか応答完了まで進める。
  # ロック内の 2 回の読出しを待ち合わせないため、直列化する実装でもデッドロックしない。
  def concurrent_key_operations(first, second)
    browsers = [admin_browser, admin_browser]
    observe_key_reads
    start_key_operation(first, browsers[0], :first)
    await_key_signal(key_entered)
    start_key_operation(second, browsers[1], :second)
    await_key_signal(key_progress)
    key_release << true
    expect_key_responses
    key_browser_bodies(browsers)
  ensure
    stop_key_threads
  end

  def pause_key_read
    return unless Thread.current[:key_operation] == :first && !Thread.current[:key_paused]

    Thread.current[:key_paused] = true
    key_entered << true
    key_release.pop
  end

  def observe_key_reads
    allow(store).to receive(:load).and_wrap_original do |original|
      current = original.call
      pause_key_read
      current
    end
    observe_key_updates if store.respond_to?(:update)
  end

  def observe_key_updates
    allow(store).to receive(:update).and_wrap_original do |original, &block|
      key_progress << true if Thread.current[:key_operation] == :second
      original.call do |current|
        pause_key_read
        block.call(current)
      end
    end
  end

  def start_key_operation(operation, browser_and_csrf, role)
    browser, csrf = browser_and_csrf
    key_threads << Thread.new do
      Thread.current[:key_operation] = role
      browser.post operation.fetch(:path), operation.fetch(:params).merge(authenticity_token: csrf)
      key_progress << true if role == :second
      browser.last_response.status
    end
  end

  def await_key_signal(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def expect_key_responses
    key_threads.each { |thread| expect(thread.join(key_completion_timeout)).not_to be_nil }
    expect(key_threads.map(&:value)).to eq([302, 302])
  end

  def key_browser_bodies(browsers)
    browsers.map do |browser, _|
      browser.follow_redirect!
      browser.last_response.body
    end
  end

  def stop_key_threads
    key_release << true
    key_threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
  end

  def issue(label) = { path: "/settings/api_keys", params: { label: label, scope: "write" } }

  def existing_keys(count = 1)
    (1..count).to_h do |index|
      ["existing#{index}", { "digest" => "d" * 64, "scope" => "read", "created_at" => "2026-10-15T09:00:00+09:00" }]
    end
  end

  it "別ラベルの並行発行を両方保存し、各ブラウザへ一度だけキーを表示する" do
    bodies = concurrent_key_operations(issue("first"), issue("second"))
    expect(store.load.fetch("api_keys").keys).to match_array(%w[first second])
    displayed = bodies.map { |body| body[/id="new-api-key">([0-9a-f]{64})</, 1] }
    expect(displayed).to all(match(/\A[0-9a-f]{64}\z/))
    expect(displayed.uniq.size).to eq(2)
  end

  it "発行と削除が重なっても削除済みキーを復活させない" do
    store.save("api_keys" => existing_keys)
    removal = { path: "/settings/api_keys/delete", params: { label: "existing1" } }
    concurrent_key_operations(issue("new"), removal)
    expect(store.load.fetch("api_keys").keys).to eq(["new"])
  end

  it "同じラベルの並行発行は一方だけ成功し、もう一方は重複を通知する" do
    bodies = concurrent_key_operations(issue("same"), issue("same"))
    expect(store.load.fetch("api_keys").keys).to eq(["same"])
    expect(bodies.count { |body| body.include?('id="new-api-key"') }).to eq(1)
    expect(bodies.count { |body| body.include?("既に発行されています") }).to eq(1)
  end

  it "19 件からの並行発行は一方だけ成功し、20 件の上限を維持する" do
    store.save("api_keys" => existing_keys(19))
    bodies = concurrent_key_operations(issue("first"), issue("second"))
    expect(store.load.fetch("api_keys").size).to eq(20)
    expect(bodies.count { |body| body.include?('id="new-api-key"') }).to eq(1)
    expect(bodies.count { |body| body.include?("上限") }).to eq(1)
  end
end
