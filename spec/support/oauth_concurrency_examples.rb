# frozen_string_literal: true

require "timeout"

RSpec.shared_examples "OAuth 操作の競合" do
  let(:oauth_entered) { Queue.new }
  let(:oauth_release) { Queue.new }
  let(:oauth_progress) { Queue.new }
  let(:oauth_threads) { [] }
  let(:oauth_lock_state) { { first: false } }
  let(:oauth_helpers) { Object.new.extend(OAuthHelpers) }

  before do
    allow(TokenStore).to receive(:backend).and_return(store)
    %i[google microsoft].each { |provider| store.clear(provider) }
    stub_request(:get, "https://www.googleapis.com/oauth2/v2/userinfo")
      .to_return(status: 200, body: '{"email":"linked@example.com"}',
                 headers: { "Content-Type" => "application/json" })
    stub_request(:post, "https://oauth2.googleapis.com/revoke").to_return(status: 200)
    observe_oauth_locks
  end

  after do
    oauth_release << true
    oauth_threads.each do |thread|
      thread.kill if thread.alive?
      thread.join
    end
    %i[google microsoft].each { |provider| store.clear(provider) }
  end

  def oauth_browser(provider)
    browser = Rack::Test::Session.new(Rack::MockSession.new(app))
    browser.get "/settings"
    csrf = browser.last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
    browser.post "/settings/login", authenticity_token: csrf, password: ENV.fetch("ADMIN_PASSWORD")
    browser.get "/auth/#{provider}"
    [browser, csrf, oauth_state(browser)]
  end

  def oauth_state(browser)
    URI.decode_www_form(URI(browser.last_response.headers.fetch("Location")).query).to_h.fetch("state")
  end

  def disconnect_oauth(browser, csrf, provider)
    path = provider == :google ? "/settings/google/disconnect" : "/disconnect"
    browser.post path, authenticity_token: csrf
    browser.last_response.status
  end

  def callback_oauth(browser, state, provider)
    browser.get "/auth/#{provider}/callback", state: state, code: "dummy-code"
    browser.last_response.status
  end

  def expired_oauth(provider)
    { "access_token" => "#{provider}-old", "refresh_token" => "#{provider}-old-refresh", "expires_at" => 1,
      "admin_email" => "original@example.com" }
  end

  def refresh_oauth(provider)
    client = provider == :google ? OAuthClients.google : OAuthClients.microsoft
    oauth_helpers.load_oauth_token(provider, client)
  end

  def oauth_endpoint(provider)
    if provider == :google
      "https://oauth2.googleapis.com/token"
    else
      "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    end
  end

  def stub_oauth_tokens(provider, pause_grant: nil)
    stub_request(:post, oauth_endpoint(provider)).to_return do |request|
      grant = URI.decode_www_form(request.body).to_h.fetch("grant_type")
      pause_oauth_http if grant == pause_grant && Thread.current[:oauth_role] == :first
      kind = grant == "refresh_token" ? "refreshed" : "linked"
      { status: 200, headers: { "Content-Type" => "application/json" },
        body: { access_token: "#{provider}-#{kind}", refresh_token: "#{provider}-#{kind}-refresh",
                expires_in: 3600 }.to_json }
    end
  end

  def pause_oauth_http
    oauth_entered << true
    oauth_release.pop
  end

  # 先行操作がロックを持つ場合だけ、後続のロック待ちを通知する。
  # 旧ルートがロックしない場合は後続の完了を待ち、先行操作より先に保存・削除させる。
  def observe_oauth_locks
    allow(store).to receive(:with_lock).and_wrap_original do |original, provider, &block|
      oauth_progress << true if waiting_oauth_second?
      original.call(provider) do
        oauth_lock_state[:first] = true if Thread.current[:oauth_role] == :first
        block.call
      end
    end
  end

  def waiting_oauth_second?
    Thread.current[:oauth_role] == :second && oauth_lock_state[:first]
  end

  def start_oauth_thread(role, &block)
    thread = Thread.new do
      Thread.current[:oauth_role] = role
      result = block.call
      oauth_progress << true if role == :second
      result
    end
    oauth_threads << thread
    thread
  end

  def await_oauth(queue)
    Timeout.timeout(5) { queue.pop }
  end

  def finish_oauth_threads
    oauth_release << true
    oauth_threads.each { |thread| expect(thread.join(5)).not_to be_nil }
    oauth_threads.map(&:value)
  end

  %i[google microsoft].each do |provider|
    it "#{provider}: 更新中の解除は更新完了後に削除し、トークンを復活させない" do
      browser, csrf, = oauth_browser(provider)
      store.save(expired_oauth(provider), provider)
      stub_oauth_tokens(provider, pause_grant: "refresh_token")
      start_oauth_thread(:first) { refresh_oauth(provider) }
      await_oauth(oauth_entered)
      start_oauth_thread(:second) { disconnect_oauth(browser, csrf, provider) }
      await_oauth(oauth_progress)
      refreshed, response = finish_oauth_threads

      expect(refreshed.token).to eq("#{provider}-refreshed")
      expect(response).to eq(302)
      expect(store.load(provider)).to be_nil
      if provider == :google
        expect(a_request(:post, "https://oauth2.googleapis.com/revoke")
          .with(body: { "token" => "google-refreshed-refresh" })).to have_been_made.once
      end
    end

    it "#{provider}: 更新中の再連携は更新完了後に新しいトークンを保存する" do
      browser, _, state = oauth_browser(provider)
      store.save(expired_oauth(provider), provider)
      stub_oauth_tokens(provider, pause_grant: "refresh_token")
      start_oauth_thread(:first) { refresh_oauth(provider) }
      await_oauth(oauth_entered)
      start_oauth_thread(:second) { callback_oauth(browser, state, provider) }
      await_oauth(oauth_progress)
      _, response = finish_oauth_threads

      expect(response).to eq(302)
      expect(store.load(provider)).to include("access_token" => "#{provider}-linked")
      expect(store.load(provider)["admin_email"]).to eq("linked@example.com") if provider == :google
    end

    it "#{provider}: 解除中に旧データを読んだ更新はロック取得後に未連携として扱う" do
      browser, csrf, = oauth_browser(provider)
      store.save(expired_oauth(provider), provider)
      stub_oauth_tokens(provider)
      allow(store).to receive(:clear).and_wrap_original do |original, value|
        pause_oauth_http if Thread.current[:oauth_role] == :first
        original.call(value)
      end
      start_oauth_thread(:first) { disconnect_oauth(browser, csrf, provider) }
      await_oauth(oauth_entered)
      start_oauth_thread(:second) { refresh_oauth(provider) }
      await_oauth(oauth_progress)
      response, refreshed = finish_oauth_threads

      expect(response).to eq(302)
      expect(refreshed).to be_nil
      expect(store.load(provider)).to be_nil
      expect(a_request(:post, oauth_endpoint(provider))).not_to have_been_made
    end

    it "#{provider}: 再連携中に旧データを読んだ更新はロック取得後に新トークンを使う" do
      browser, _, state = oauth_browser(provider)
      store.save(expired_oauth(provider), provider)
      stub_oauth_tokens(provider, pause_grant: "authorization_code")
      start_oauth_thread(:first) { callback_oauth(browser, state, provider) }
      await_oauth(oauth_entered)
      start_oauth_thread(:second) { refresh_oauth(provider) }
      await_oauth(oauth_progress)
      response, refreshed = finish_oauth_threads

      expect(response).to eq(302)
      expect(refreshed.token).to eq("#{provider}-linked")
      expect(a_request(:post, oauth_endpoint(provider)).with(body: hash_including("grant_type" => "refresh_token")))
        .not_to have_been_made
    end

    it "#{provider}: 更新失敗は未連携として返し、保存済みトークンを消さない" do
      saved = expired_oauth(provider)
      store.save(saved, provider)
      stub_request(:post, oauth_endpoint(provider))
        .to_return(status: 400, body: '{"error":"invalid_grant"}',
                   headers: { "Content-Type" => "application/json" })
      refreshed = nil
      expect { refreshed = refresh_oauth(provider) }.to output(/\[oauth\] トークン更新失敗/).to_stderr

      expect(refreshed).to be_nil
      expect(store.load(provider)).to eq(saved)
    end
  end

  it "Google の revoke 中は再連携の code 交換を開始せず、解除後に交換・保存する" do
    disconnect_browser, csrf, = oauth_browser(:google)
    callback_browser, _, state = oauth_browser(:google)
    store.save(expired_oauth(:google), :google)
    stub_oauth_tokens(:google)
    stub_request(:post, "https://oauth2.googleapis.com/revoke").to_return do
      pause_oauth_http
      { status: 200 }
    end
    start_oauth_thread(:first) { disconnect_oauth(disconnect_browser, csrf, :google) }
    await_oauth(oauth_entered)
    start_oauth_thread(:second) { callback_oauth(callback_browser, state, :google) }
    await_oauth(oauth_progress)
    expect(a_request(:post, oauth_endpoint(:google))).not_to have_been_made
    expect(finish_oauth_threads).to eq([302, 302])
    expect(store.load(:google)).to include("access_token" => "google-linked", "admin_email" => "linked@example.com")
  end

  it "Google のロック中も Microsoft の解除は完了する" do
    browser, csrf, = oauth_browser(:microsoft)
    store.save(expired_oauth(:microsoft), :microsoft)
    start_oauth_thread(:first) { store.with_lock(:google) { pause_oauth_http } }
    await_oauth(oauth_entered)
    disconnect = start_oauth_thread(:second) { disconnect_oauth(browser, csrf, :microsoft) }
    expect(disconnect.join(5)).not_to be_nil
    expect(disconnect.value).to eq(302)
    expect(store.load(:microsoft)).to be_nil
    finish_oauth_threads
  end

  it "Google の revoke がタイムアウトしても解除はローカル削除を完了する" do
    browser, csrf, = oauth_browser(:google)
    store.save(expired_oauth(:google), :google)
    stub_request(:post, "https://oauth2.googleapis.com/revoke").to_timeout

    expect(disconnect_oauth(browser, csrf, :google)).to eq(302)
    expect(store.load(:google)).to be_nil
  end
end
