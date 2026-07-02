# frozen_string_literal: true

RSpec.describe "XSS（出力の自動エスケープ）" do
  let(:settings) do
    {
      "business_start" => "09:00", "business_end" => "18:00", "business_days" => [1, 2, 3, 4, 5],
      "lunch_start" => "11:00", "lunch_end" => "14:00", "lunch_minutes" => 60
    }
  end

  before do
    # Google 連携済みにして調整画面にフォームを描画させる（API 呼び出しは発生しない範囲で検証）。
    allow(TokenStore).to receive(:load).and_return({ "access_token" => "fake", "expires_at" => 4_102_444_800 })
    allow(SettingsStore).to receive(:load).and_return(settings)
  end

  it "クエリの start_date がエスケープされて出力される" do
    token = TicketStore.create
    get "/t/#{token}", start_date: '"><script>alert(1)</script>'
    expect(last_response.body).not_to include('"><script>alert(1)</script>')
    expect(last_response.body).to include("&lt;script&gt;")
  end

  def stub_google_calendar_api
    stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
  end

  # 依頼者名・予定名に HTML を入れて予約を成立させる（保存型 XSS の攻撃入力を作る）。
  def create_booking_with(text)
    stub_google_calendar_api
    ticket = TicketStore.create
    date = Date.today + 7
    date += 1 until (1..5).cover?(date.wday)
    post "/schedule", authenticity_token: csrf_token, token: ticket, title: text, requester: text,
                      slot: "#{date}T10:00:00+09:00/#{date}T10:30:00+09:00"
    expect(last_response.status).to eq(302) # 予約自体は成立していること（前提の検証）
    ticket
  end

  it "予約完了 flash の依頼者名・予定名がエスケープされる" do
    evil = '<img src=x onerror="alert(1)">'
    create_booking_with(evil)
    follow_redirect! # 完了画面（flash 表示先）へ
    expect(last_response.body).not_to include(evil)
    expect(last_response.body).to include("&lt;img src=x")
  end

  it "/tickets 一覧の依頼者名・予定名（使用済みチケットの登録内容）がエスケープされる" do
    evil = "<script>alert(2)</script>"
    create_booking_with(evil)
    login_admin!
    get "/tickets"
    expect(last_response.body).not_to include(evil)
    expect(last_response.body).to include("&lt;script&gt;alert(2)&lt;/script&gt;")
  end

  it "Outlook 由来の件名・場所が /sync の差分一覧でエスケープされる" do
    evil = "<script>alert(3)</script>"
    outlook_event = {
      "id" => "ev1", "subject" => evil, "location" => { "displayName" => evil },
      "start" => { "dateTime" => "#{Date.today + 1}T01:00:00.000" },
      "end" => { "dateTime" => "#{Date.today + 1}T02:00:00.000" }, "isAllDay" => false
    }
    stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, %r{graph\.microsoft\.com/v1\.0/me/calendarView})
      .to_return(status: 200, body: { "value" => [outlook_event] }.to_json,
                 headers: { "Content-Type" => "application/json" })
    allow(SettingsStore).to receive(:save)

    login_admin!
    post "/check", authenticity_token: csrf_token, range_mode: "days", sync_window_days: "30"
    get "/sync"
    expect(last_response.body).not_to include(evil)
    expect(last_response.body).to include("&lt;script&gt;alert(3)&lt;/script&gt;")
  end
end
