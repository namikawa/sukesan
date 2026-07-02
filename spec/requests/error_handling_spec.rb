# frozen_string_literal: true

RSpec.describe "エラーハンドリング" do
  # テスト環境の既定は raise_errors: true（例外がそのまま伝播）のため、
  # 本番相当（error ハンドラで処理）に切り替えて検証し、終了後に必ず戻す。
  around do |example|
    app.set :raise_errors, false
    example.run
  ensure
    app.set :raise_errors, true
  end

  it "500 の本文に内部情報を出さず、ログに例外クラスと発生位置だけを残す" do
    allow(TicketStore).to receive(:find).and_raise(RuntimeError, "internal-secret-detail")

    expect { get "/t/whatever" }.to output(/\[error\] RuntimeError at .+:\d+/).to_stderr
    expect(last_response.status).to eq(500)
    expect(last_response.body).to include("エラーが発生しました")
    expect(last_response.body).not_to include("internal-secret-detail")
  end
end
