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

  def initialize(lock:, availability:, calendar_client:, event_id_key:)
    @lock = lock
    @availability = availability
    @calendar_client = calendar_client
    @event_id_key = event_id_key
  end

  # token を消費し、event を Google カレンダーへ登録する。予約は 1 件ずつ直列化し、別トークン同士が
  # 同じ枠をほぼ同時に予約しても、後続はロック内の再確認で先行予約を検知して弾ける。
  def call(token:, event:, ticket_attrs:, attendees: [], request_meet: false)
    @lock.synchronize do
      # ロック内で最新の空き状況を取り直して再検証する（依頼者が見た古い結果は信用しない）。
      return Result.new(status: :slot_taken) unless @availability.slot_available?(event.starts_at, event.ends_at)

      # 二重登録を防ぐため、カレンダー登録より先に token を使用済みにする。
      # 同時送信で既に使われていれば false（登録は行わない）。
      return Result.new(status: :ticket_used) unless TicketStore.use!(token, attrs: ticket_attrs)

      register(token, event, attendees, request_meet)
    end
  end

  private

  def register(token, event, attendees, request_meet)
    response = @calendar_client.create_event(event, attendees: attendees, request_meet: request_meet,
                                                    id: event_id_for(token))
    meet_link = request_meet ? GoogleCalendarClient.meet_link(response) : nil
    Result.new(status: :ok, meet_link: meet_link)
  rescue GoogleCalendarClient::Conflict
    # 同じ token の決定的 ID が既に存在する＝前回の試行で作成済み。重複させず成功扱いにする
    # （HTTP タイムアウト等で「Google 側は成功・アプリ側は例外」になった後の再試行を冪等にする）。
    Result.new(status: :ok, meet_link: nil)
  rescue StandardError
    # 登録に失敗したときは token を有効へ戻し、再試行できるようにする。
    TicketStore.reactivate!(token)
    Result.new(status: :api_failure)
  end

  # token から決定的に導く Google イベント ID。再試行で同じ ID になり、Google 側の一意制約（409）で
  # 重複作成を防ぐ。token は直接使わず HMAC で隠す（hex は base32hex の部分集合で ID 制約を満たす）。
  def event_id_for(token)
    "sukesan#{OpenSSL::HMAC.hexdigest('SHA256', @event_id_key, token.to_s)[0, 40]}"
  end
end
