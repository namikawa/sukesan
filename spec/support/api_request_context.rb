# frozen_string_literal: true

# 他システム向け API（/api/v1）のリクエストスペックで共通の API キー・認証ヘッダ・ヘルパ。
# 使う側で明示的に include_context する（metadata による暗黙適用はしない）。
# 単一キー構成・独自のキーセットを検証するスペック（api_events / api_scope）は、その差異自体が
# テスト対象なのでこのコンテキストを使わない。
RSpec.shared_context "API リクエスト" do
  # 発行済みキー: サーバ側には SHA-256 ダイジェストのみ保存されている（画面発行方式）。
  let(:read_key) { "r" * 64 }
  let(:write_key) { "w" * 64 }
  let(:created_at) { "2026-07-01T09:00:00+09:00" }
  let(:api_keys) do
    {
      "read-sys" => { "digest" => Digest::SHA256.hexdigest(read_key), "created_at" => created_at,
                      "scope" => "read" },
      "write-sys" => { "digest" => Digest::SHA256.hexdigest(write_key), "created_at" => created_at,
                       "scope" => "write" }
    }
  end
  let(:read_auth) { { "HTTP_AUTHORIZATION" => "Bearer #{read_key}" } }
  let(:write_auth) { { "HTTP_AUTHORIZATION" => "Bearer #{write_key}" } }

  # API のチケット識別子（監査ログ・アクセスログと同じ HMAC 短縮 ID）。
  def api_id(token)
    "~#{MaskedAccessLogger.token_short_id(LOG_TOKEN_ID_KEY, token)}"
  end

  # 書き込み系は JSON ボディで送る（Rack::Test は文字列をそのままボディにする）。
  def post_json(path, body = {}, headers = write_auth)
    post path, JSON.generate(body), headers.merge("CONTENT_TYPE" => "application/json")
  end
end
