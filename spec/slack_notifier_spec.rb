# frozen_string_literal: true

RSpec.describe SlackNotifier do
  let(:webhook) { "https://hooks.slack.com/services/T00/B00/xxxx" }

  after { described_class.configure(nil) } # テスト既定（no-op）へ戻す

  it "configure 済みなら text を含む JSON を webhook へ POST する" do
    stub = stub_request(:post, webhook)
           .with(headers: { "Content-Type" => "application/json" },
                 body: { "text" => "予約が入りました" }.to_json)
           .to_return(status: 200, body: "ok")
    described_class.configure(webhook)
    described_class.notify("予約が入りました")

    expect(stub).to have_been_requested
  end

  it "configure されていなければ HTTP リクエストは発生しない（テスト環境の既定）" do
    described_class.configure(nil)
    described_class.notify("何か")

    expect(a_request(:post, /hooks\.slack\.com/)).not_to have_been_made
  end

  it "空文字の URL では configure せず通知しない" do
    described_class.configure("")
    described_class.notify("何か")

    expect(a_request(:post, /hooks\.slack\.com/)).not_to have_been_made
  end

  it "送信先が 500 を返しても例外を伝播させない" do
    stub_request(:post, webhook).to_return(status: 500, body: "error")
    described_class.configure(webhook)

    expect { described_class.notify("x") }.not_to raise_error
  end

  it "タイムアウト・接続不可でも例外を伝播させず、クラス名だけを warn する" do
    stub_request(:post, webhook).to_raise(Net::OpenTimeout)
    described_class.configure(webhook)

    expect do
      expect { described_class.notify("x") }.not_to raise_error
    end.to output(/\[SlackNotifier\] 通知の送信失敗: Net::OpenTimeout/).to_stderr
  end

  it "warn に webhook URL を出さない（秘密情報の漏えい防止）" do
    stub_request(:post, webhook).to_raise(SocketError)
    described_class.configure(webhook)

    expect { described_class.notify("x") }.to output(/\A(?!.*hooks\.slack\.com).*\z/m).to_stderr
  end

  describe "メンション（SLACK_MENTION）" do
    it "channel 指定なら text 先頭に <!channel> が付く（大文字小文字不問）" do
      stub = stub_request(:post, webhook)
             .with(body: { "text" => "<!channel> 予約が入りました" }.to_json)
             .to_return(status: 200)
      described_class.configure(webhook, mention: "Channel")
      described_class.notify("予約が入りました")

      expect(stub).to have_been_requested
    end

    it "here 指定なら text 先頭に <!here> が付く" do
      stub = stub_request(:post, webhook)
             .with(body: { "text" => "<!here> 予約が入りました" }.to_json)
             .to_return(status: 200)
      described_class.configure(webhook, mention: "here")
      described_class.notify("予約が入りました")

      expect(stub).to have_been_requested
    end

    it "メンバー ID 指定なら text 先頭に <@ID>（upcase 済み）が付く" do
      stub = stub_request(:post, webhook)
             .with(body: { "text" => "<@U0ABC123> 予約が入りました" }.to_json)
             .to_return(status: 200)
      described_class.configure(webhook, mention: "u0abc123")
      described_class.notify("予約が入りました")

      expect(stub).to have_been_requested
    end

    it "不正値ならメンションを付けず、値を出さず warn する（fail-safe）" do
      stub = stub_request(:post, webhook)
             .with(body: { "text" => "予約が入りました" }.to_json)
             .to_return(status: 200)

      expect { described_class.configure(webhook, mention: "@secret-team") }
        .to output(/\[SlackNotifier\] SLACK_MENTION の値が不正/).to_stderr
      described_class.notify("予約が入りました")

      expect(stub).to have_been_requested
    end

    it "未設定（nil）ならメンションを付けない" do
      stub = stub_request(:post, webhook)
             .with(body: { "text" => "予約が入りました" }.to_json)
             .to_return(status: 200)
      described_class.configure(webhook)
      described_class.notify("予約が入りました")

      expect(stub).to have_been_requested
    end
  end
end
