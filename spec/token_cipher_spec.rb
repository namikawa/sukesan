# frozen_string_literal: true

require "digest"

RSpec.describe TokenCipher do
  let(:key) { Digest::SHA256.digest("test-key") }
  let(:cipher) { described_class.new(key) }

  it "暗号化したものを復号すると元に戻る" do
    plaintext = '{"access_token":"AT","refresh_token":"RT"}'
    expect(cipher.decrypt(cipher.encrypt(plaintext))).to eq(plaintext)
  end

  it "暗号文は平文を含まない" do
    blob = cipher.encrypt("super-secret-token")
    expect(blob).not_to include("super-secret-token")
  end

  it "鍵が異なると復号できない" do
    blob = cipher.encrypt("secret")
    other = described_class.new(Digest::SHA256.digest("other-key"))
    expect { other.decrypt(blob) }.to raise_error(OpenSSL::Cipher::CipherError)
  end

  it "改ざんされた暗号文は復号できない（GCM 認証タグ検証）" do
    raw = Base64.strict_decode64(cipher.encrypt("secret"))
    tampered = Base64.strict_encode64(raw[0..-2] + (raw[-1].ord ^ 0x01).chr)
    expect { cipher.decrypt(tampered) }.to raise_error(OpenSSL::Cipher::CipherError)
  end
end
