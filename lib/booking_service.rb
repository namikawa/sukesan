# frozen_string_literal: true

require "openssl"
require_relative "ticket_store"
require_relative "google_calendar_client"

# ワンタイム URL からの予約登録（中核トランザクション）を担うサービス。
#
# 二重予約防止・チケット消費順序・外部 API 失敗時のロールバックという整合性/セキュリティの核を、
# HTTP 層から分離して単体テスト可能にする。Web 関心（params 検証・HTTP ステータス・session/flash）は
# ルート側に残す。
class BookingService
  # status: :ok / :slot_taken / :ticket_used / :api_failure
  Result = Struct.new(:status, :meet_link, keyword_init: true)

  # 入力（token・冪等キーなど）から決定的に導く Google イベント ID。再試行で同じ ID になり、
  # Google 側の一意制約（409）で重複作成を防ぐ。入力は直接使わず HMAC で隠す
  # （hex は base32hex の部分集合で ID 制約を満たす）。material に用途を含めて ID 空間を分ける。
  def self.event_id(key, material)
    "sukesan#{OpenSSL::HMAC.hexdigest('SHA256', key, material)[0, 40]}"
  end

  def initialize(lock:, availability:, calendar_client:, event_id_key:)
    @lock = lock
    @availability = availability
    @calendar_client = calendar_client
    @event_id_key = event_id_key
  end

  # token を消費し、event を Google カレンダーへ登録する。予約は 1 件ずつ直列化し、別トークン同士が
  # 同じ枠をほぼ同時に予約しても、後続はロック内の再確認で先行予約を検知して弾ける。
  # send_invites: true ならゲストのオプトインとして参加者へ Google の標準招待メールを送る（既定は送らない）。
  # private_event: true なら visibility=private で作成する（共有相手には「予定あり」とだけ表示）。
  # event_id: 登録に使う Google イベント ID（未指定なら token から導く）。外部システムからの直接予約は
  # Idempotency-Key 由来の ID を渡し、リトライ時の重複作成を Google 側の 409 で吸収する。
  def call(token:, event:, ticket_attrs:, attendees: [], request_meet: false, send_invites: false,
           private_event: false, event_id: nil)
    @lock.synchronize do
      # ロック内で最新の空き状況を取り直して再検証する（依頼者が見た古い結果は信用しない）。
      return Result.new(status: :slot_taken) unless @availability.slot_available?(event.starts_at, event.ends_at)

      # 登録するイベント ID はチケットにも保存する（取消は「チケット保存値の event_id」だけを対象にし、
      # クライアントから event id を受け取らないため）。
      id = event_id || self.class.event_id(@event_id_key, token.to_s)
      attrs = ticket_attrs.merge("event_id" => id)

      # 二重登録を防ぐため、カレンダー登録より先に token を使用済みにする。
      # 同時送信で既に使われていれば false（登録は行わない）。
      return Result.new(status: :ticket_used) unless TicketStore.use!(token, attrs: attrs)

      register(token, event, attendees, request_meet: request_meet, send_invites: send_invites,
                                        private_event: private_event, id: id)
    end
  end

  private

  def register(token, event, attendees, request_meet:, send_invites:, private_event:, id:)
    response = @calendar_client.create_event(event, attendees: attendees, request_meet: request_meet,
                                                    send_updates: send_invites ? "all" : "none",
                                                    private_event: private_event, id: id)
    meet_link = request_meet ? GoogleCalendarClient.meet_link(response) : nil
    Result.new(status: :ok, meet_link: meet_link)
  rescue GoogleCalendarClient::Conflict
    # 同じ token の決定的 ID が既に存在する＝前回の試行で作成済み。重複させず成功扱いにする
    # （HTTP タイムアウト等で「Google 側は成功・アプリ側は例外」になった後の再試行を冪等にする）。
    Result.new(status: :ok, meet_link: nil)
  rescue StandardError => e
    # 登録に失敗したときは token を有効へ戻し、再試行できるようにする。
    # 原因調査のため例外クラスのみ記録する（メッセージは API 応答＝秘密を含み得るため出さない）。
    warn "[BookingService] 登録失敗: #{e.class}（token を有効へ戻します）"
    TicketStore.reactivate!(token)
    Result.new(status: :api_failure)
  end
end
