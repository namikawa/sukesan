# frozen_string_literal: true

require "openssl"
require "time"
require_relative "ticket_store"
require_relative "google_calendar_client"

# ワンタイム URL からの予約登録（中核トランザクション）を担うサービス。
#
# 二重予約防止・チケット消費順序・外部 API 失敗時のロールバックという整合性/セキュリティの核を、
# HTTP 層から分離して単体テスト可能にする。Web 関心（params 検証・HTTP ステータス・session/flash）は
# ルート側に残す。
class BookingService
  # status: :ok / :slot_taken / :ticket_used / :api_failure / :idempotency_conflict
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
                                        private_event: private_event, id: id, id_from_caller: !event_id.nil?)
    end
  end

  private

  # id_from_caller: 登録に使う ID を呼び出し側が指定したか（＝ token 由来でないか）。409 の扱いを分けるために使う。
  def register(token, event, attendees, request_meet:, send_invites:, private_event:, id:, id_from_caller:)
    response = @calendar_client.create_event(event, attendees: attendees, request_meet: request_meet,
                                                    send_updates: send_invites ? "all" : "none",
                                                    private_event: private_event, id: id)
    ok_result(response, request_meet)
  rescue GoogleCalendarClient::Conflict
    conflict_result(token, id_from_caller)
  rescue StandardError => e
    recover_or_fail(token, e, id: id, event: event, request_meet: request_meet)
  end

  def ok_result(response, request_meet)
    Result.new(status: :ok, meet_link: request_meet ? GoogleCalendarClient.meet_link(response) : nil)
  end

  # 同じ event id が既に存在する（409）ときの扱い。
  # token 由来の ID は同じチケットの再試行でしか衝突しないため、前回の試行で作成済みとみなして成功にする
  # （HTTP タイムアウト等で「Google 側は成功・アプリ側は例外」になった後の再試行を冪等にする）。
  # 呼び出し側が指定した ID（Idempotency-Key 由来）は、取り消して削除済みの予定とも衝突する
  # （Google は削除したイベントの ID を再利用できない）。予定が無いのに成功を返さないよう、
  # token を有効へ戻したうえでキーの衝突として呼び出し側へ伝える。
  def conflict_result(token, id_from_caller)
    return Result.new(status: :ok, meet_link: nil) unless id_from_caller

    TicketStore.reactivate!(token)
    Result.new(status: :idempotency_conflict)
  end

  # 応答の受信に失敗しても Google 側では作成できていることがある（タイムアウト等）。存在を 1 回だけ
  # 確認し、今回の登録が成立していればチケットを used のまま成功として扱う（管理外の予定を残さない）。
  # 確認できない・別の予定だった・確認自体が失敗した場合は曖昧なので、従来どおり token を有効へ戻して
  # 失敗を返す（リトライすれば Google の 409 に収束するため、ここで衝突と区別はしない）。
  # 原因調査のため例外クラスのみ記録する（メッセージは API 応答＝秘密を含み得るため出さない）。
  def recover_or_fail(token, error, id:, event:, request_meet:)
    created = created_event(id, event)
    return ok_result(created, request_meet) if created

    warn "[BookingService] 登録失敗: #{error.class}（token を有効へ戻します）"
    TicketStore.reactivate!(token)
    Result.new(status: :api_failure)
  end

  # 今回の登録でできた予定を取得する（無い・削除済み・別の予定・確認自体が失敗した場合は nil）。
  # 冪等キー由来の ID は、一覧の対象（30 日）より前に同じキーで登録した予定や、同じキーの並行実行が
  # 作った予定とも一致し得る。別の予定を今回の成功と誤認しないよう、時間帯の一致まで確認する。
  def created_event(id, event)
    found = @calendar_client.get_event(id)
    return nil unless found.is_a?(Hash) && found["status"] != "cancelled"

    found if same_period?(found, event)
  rescue StandardError => e
    warn "[BookingService] 登録結果の確認失敗: #{e.class}"
    nil
  end

  # 取得した予定の時間帯が、今回登録しようとした枠と同じか。オフセット表記の違いを吸収するため
  # Time に変換して比較する（dateTime を持たない＝終日予定・パースできない値は不一致として扱う）。
  def same_period?(found, event)
    parse_time(found.dig("start", "dateTime")) == event.starts_at &&
      parse_time(found.dig("end", "dateTime")) == event.ends_at
  end

  def parse_time(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end
end
