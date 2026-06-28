# frozen_string_literal: true

require "oauth_clients"

RSpec.describe OAuthClients do
  it "Google クライアントに接続・読み取りタイムアウトを設定する" do
    opts = described_class.google.options[:connection_opts]
    expect(opts.dig(:request, :open_timeout)).to eq(OAuthClients::OPEN_TIMEOUT)
    expect(opts.dig(:request, :timeout)).to eq(OAuthClients::READ_TIMEOUT)
  end

  it "Microsoft クライアントにも同じタイムアウトを設定する" do
    opts = described_class.microsoft.options[:connection_opts]
    expect(opts.dig(:request, :open_timeout)).to eq(OAuthClients::OPEN_TIMEOUT)
    expect(opts.dig(:request, :timeout)).to eq(OAuthClients::READ_TIMEOUT)
  end
end
