# frozen_string_literal: true

require "stringio"

RSpec.describe AuditLog do
  after { described_class.configure(nil) } # テスト既定（no-op）へ戻す

  it "イベントを 1 行 JSON で記録する" do
    io = StringIO.new
    described_class.configure(io)
    described_class.record(:login_failure, ip: "203.0.113.1", target: "~abcd1234")

    entry = JSON.parse(io.string)
    expect(entry).to include("type" => "audit", "event" => "login_failure",
                             "ip" => "203.0.113.1", "target" => "~abcd1234")
    expect(entry["at"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    expect(io.string).to end_with("\n")
  end

  it "target 無しのイベントは target キーを含めない" do
    io = StringIO.new
    described_class.configure(io)
    described_class.record(:login_success, ip: "203.0.113.1")

    expect(JSON.parse(io.string)).not_to have_key("target")
  end

  it "configure されていなければ何も出力しない（テスト環境の既定）" do
    described_class.configure(nil)
    expect { described_class.record(:login_success, ip: "x") }.not_to raise_error
  end

  it "書き込み失敗でも例外を伝播させない（リクエスト処理を止めない）" do
    device = instance_double(Logger::LogDevice)
    allow(device).to receive(:write).and_raise(IOError)
    described_class.configure(device)

    expect do
      expect { described_class.record(:login_success, ip: "x") }.not_to raise_error
    end.to output(/\[AuditLog\] 書き込み失敗: IOError/).to_stderr
  end
end
