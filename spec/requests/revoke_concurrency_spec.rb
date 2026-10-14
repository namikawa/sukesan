# frozen_string_literal: true

require "timeout"

RSpec.describe "仮押さえ作成中のチケット無効化" do
  include_context "API リクエスト"

  %i[admin api].each do |route|
    it "#{route} の無効化は作成完了を待ち、作られた仮押さえをすべて削除する" do
      entered = Queue.new
      release = Queue.new
      revoke_progress = Queue.new
      events = []
      token = TicketStore.create
      TokenStore.save("access_token" => "fake", "expires_at" => 4_102_444_800)
      SettingsStore.save("api_keys" => api_keys)
      login_admin!
      csrf = csrf_token
      headers = write_auth
      id = api_id(token)
      availability = double(slot_available?: true)
      client = GoogleCalendarClient.new(OAuth2::AccessToken.new(OAuthClients.google, "fake"))
      service = HoldService.new(lock: BOOKING_LOCK, availability: availability, calendar_client: client,
                                event_id_key: EVENT_ID_KEY)
      start = Time.now + 86_400
      slots = [[start, start + 1800], [start + 3600, start + 5400]]

      stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events}).to_return do |request|
        entered << true if events.empty?
        release.pop if events.empty?
        events << JSON.parse(request.body).fetch("id")
        { status: 200, body: "{}", headers: { "Content-Type" => "application/json" } }
      end
      stub_request(:delete, %r{googleapis\.com/calendar/v3/calendars/primary/events/}).to_return do |request|
        events.delete(request.uri.path.split("/").last)
        { status: 204, body: "" }
      end
      # 無効化側がロック待ちに入ったことを通知する。旧実装では応答完了の通知が先に届く。
      allow(BOOKING_LOCK).to receive(:synchronize).and_wrap_original do |original, &block|
        revoke_progress << true if Thread.current[:revoking]
        original.call(&block)
      end

      holding = Thread.new do
        service.hold(token: token, requester: "依頼者", title: "打合せ", slots: slots, holder_key: "holder")
      end
      Timeout.timeout(3) { entered.pop }
      revoking = Thread.new do
        Thread.current[:revoking] = true
        if route == :admin
          post "/tickets/revoke", authenticity_token: csrf, token: token
        else
          post "/api/v1/tickets/#{id}/revoke", {}, headers
        end
        revoke_progress << true
        last_response
      end
      Timeout.timeout(3) { revoke_progress.pop }
      release << true

      expect(holding.join(3)).not_to be_nil
      expect(revoking.join(3)).not_to be_nil
      expect(holding.value.status).to eq(:ok)
      expect(revoking.value.status).to eq(route == :admin ? 302 : 200)
      expect(TicketStore.status(TicketStore.find(token))).to eq("revoked")
      expect(events).to be_empty
    ensure
      release << true if release
      [holding, revoking].compact.each do |thread|
        thread.kill if thread.alive?
        thread.join
      end
    end
  end
end
