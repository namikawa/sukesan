# frozen_string_literal: true

require "json"
require "time"

# 管理操作・認証・予約の監査ログ。1 イベント 1 行の JSON で記録する
# （ローカルはファイル、Cloud Run は stdout ＝ Cloud Logging がフィールドを解釈できる形）。
#
# 記録するのは 時刻・イベント種別・クライアント IP・非機微な対象識別子 のみ。
# 秘密（password/token/code）と PII（依頼者名・予定名）は記録しない。チケットの識別には
# アクセスログと同じ HMAC 短縮 ID（MaskedAccessLogger.token_short_id）を使い、ログ間で相関できるようにする。
module AuditLog
  module_function

  # 起動時に出力先（write に応答するもの: Logger::LogDevice / $stdout）を設定する。
  # テスト環境では configure を呼ばないため no-op のままになる。
  def configure(device)
    @device = device
  end

  def record(event, ip:, target: nil)
    return if @device.nil?

    entry = { "type" => "audit", "event" => event.to_s, "ip" => ip.to_s, "at" => Time.now.iso8601 }
    entry["target"] = target if target
    @device.write("#{JSON.generate(entry)}\n")
  rescue StandardError => e
    # 監査ログの書き込み失敗でリクエスト処理を止めない（原因調査用に種別だけ残す）。
    warn "[AuditLog] 書き込み失敗: #{e.class}"
  end
end
