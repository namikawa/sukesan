# frozen_string_literal: true

RSpec.describe "監査ログの記録" do
  before { allow(AuditLog).to receive(:record) }

  it "ログイン成功・失敗を記録する" do
    login_admin!
    expect(AuditLog).to have_received(:record).with(:login_success, ip: anything)

    post "/settings/login", authenticity_token: csrf_token, password: "wrong"
    expect(AuditLog).to have_received(:record).with(:login_failure, ip: anything)
  end

  it "チケット発行は生 token でなく HMAC 短縮 ID を記録する" do
    login_admin!
    allow(TicketStore).to receive(:create).and_return("raw-token-value")

    post "/tickets", authenticity_token: csrf_token
    expect(AuditLog).to have_received(:record)
      .with(:ticket_create, ip: anything, target: a_string_matching(/\A~[0-9a-f]{8}\z/))
  end

  it "予約の成立を短縮 ID で記録する" do
    allow(TokenStore).to receive(:load).and_return({ "access_token" => "fake", "expires_at" => 4_102_444_800 })
    result = BookingService::Result.new(status: :ok, meet_link: nil)
    allow(BookingService).to receive(:new).and_return(instance_double(BookingService, call: result))
    ticket = TicketStore.create
    date = future_business_day

    post "/schedule", authenticity_token: csrf_token, token: ticket, title: "打合せ", requester: "山田",
                      slot: "#{date}T10:00:00+09:00/#{date}T10:30:00+09:00"
    expect(last_response.status).to eq(302)
    expect(AuditLog).to have_received(:record)
      .with(:booking_created, ip: anything, target: a_string_matching(/\A~[0-9a-f]{8}\z/))
  end

  it "連携解除を記録する" do
    login_admin!
    allow(TokenStore).to receive(:load).and_return(nil) # revoke 用の読み込み（HTTP を発生させない）
    allow(TokenStore).to receive(:clear)

    post "/settings/google/disconnect", authenticity_token: csrf_token
    expect(AuditLog).to have_received(:record).with(:oauth_disconnect, ip: anything, target: "google")
  end
end
