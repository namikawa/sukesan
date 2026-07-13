# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# ゲスト操作（予約・仮押さえ・決定・全取りやめ）を管理者の Slack へ知らせる通知。
# Incoming Webhook に {"text": "..."} を JSON POST するだけの薄いクライアント。
#
# 設計は AuditLog と揃える: 起動時に configure（webhook URL を保持）し、テスト環境では
# configure を呼ばないため no-op のままになる。ENV が未設定・空なら configure しない＝通知無効
# （deny-by-default）。
#
# 通知はあくまでベストエフォート。送信失敗（HTTP エラー・タイムアウト・接続不可）は絶対に
# 呼び出し元（予約・仮押さえ処理）へ伝播させない。webhook URL は秘密情報なので、ログ・例外
# メッセージには一切出さない（クラス名だけを残す）。
module SlackNotifier
  module_function

  # 接続・読み取りとも短く切る。ゲストのレスポンス（予約完了画面への遷移）を Slack 送信で
  # 待たせないため。通知が数秒で届かなくても業務影響はなく、遅延より握りつぶしを優先する。
  OPEN_TIMEOUT = 3 # 秒
  READ_TIMEOUT = 3 # 秒

  # 起動時に Incoming Webhook の URL を設定する。nil/空なら configure せず通知無効のまま。
  # テスト環境では呼ばない（AuditLog と同じく既定 no-op）。
  def configure(webhook_url)
    url = webhook_url.to_s.strip
    @uri = url.empty? ? nil : URI.parse(url)
  end

  def notify(text)
    return if @uri.nil?

    request = Net::HTTP::Post.new(@uri.request_uri, "Content-Type" => "application/json")
    request.body = JSON.generate("text" => text.to_s)
    http_client.request(request)
    nil
  rescue StandardError => e
    # 通知はベストエフォート。失敗しても呼び出し元の処理は止めない（クラス名だけ残す。
    # webhook URL・レスポンス本文は秘密・不要なので出さない）。
    warn "[SlackNotifier] 通知の送信失敗: #{e.class}"
    nil
  end

  def http_client
    http = Net::HTTP.new(@uri.host, @uri.port)
    http.use_ssl = (@uri.scheme == "https")
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http
  end
end
