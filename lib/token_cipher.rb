# frozen_string_literal: true

require "openssl"
require "base64"

# センシティブな情報（OAuth トークン等）を AES-256-GCM で暗号化/復号する。
# 出力は base64(iv || auth_tag || ciphertext)。改ざんは復号時に検知され例外になる。
class TokenCipher
  ALGORITHM = "aes-256-gcm"
  IV_LENGTH = 12
  TAG_LENGTH = 16

  # key は 32 バイト（AES-256）。
  def initialize(key)
    @key = key
  end

  def encrypt(plaintext)
    cipher = OpenSSL::Cipher.new(ALGORITHM)
    cipher.encrypt
    cipher.key = @key
    iv = cipher.random_iv
    ciphertext = cipher.update(plaintext) + cipher.final
    Base64.strict_encode64(iv + cipher.auth_tag + ciphertext)
  end

  def decrypt(blob)
    raw = Base64.strict_decode64(blob)
    # 短すぎるデータ（IV＋認証タグ未満）は復号不能。nil スライス由来の TypeError 等で呼び出し側の
    # fail-closed な rescue（ArgumentError 等の列挙）から漏れないよう、ArgumentError に正規化する。
    raise ArgumentError, "ciphertext too short" if raw.bytesize < IV_LENGTH + TAG_LENGTH

    cipher = OpenSSL::Cipher.new(ALGORITHM)
    cipher.decrypt
    cipher.key = @key
    cipher.iv = raw[0, IV_LENGTH]
    cipher.auth_tag = raw[IV_LENGTH, TAG_LENGTH]
    cipher.update(raw[(IV_LENGTH + TAG_LENGTH)..]) + cipher.final
  end
end
