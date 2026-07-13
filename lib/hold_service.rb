# frozen_string_literal: true

require "openssl"
require "time"
require_relative "ticket_store"
require_relative "ticket_status"
require_relative "google_calendar_client"
require_relative "event"

# 複数カレンダー仮押さえの中核トランザクション（作成・決定・個別削除・全取りやめ）を担うサービス。
#
# BookingService と同じく、整合性の核（ロックによる直列化・チケットの状態遷移の順序・
# 失敗時のロールバック・決定的イベント ID による冪等化）を HTTP 層から分離する。
# Web 関心（params 検証・holder 照合・HTTP ステータス・flash）はルート側に残す。
#
# セキュリティ上の設計制約: 操作対象のイベント ID はチケットに保存した値のみを使う。
# クライアント入力から event id を受け取ってはならない（任意イベント削除への横展開を防ぐ）。
class HoldService
  MAX_HOLDS = 5
  TITLE_PREFIX = "[仮ブロック] "

  # status: :ok / :slot_taken / :ticket_used / :not_held / :api_failure
  # failed_deletes: 削除に失敗した仮押さえイベント数（[仮ブロック] のままカレンダーに残る）
  # patch_failed: 決定イベントの件名更新に失敗した（決定自体は成立している）
  Result = Struct.new(:status, :meet_link, :failed_deletes, :patch_failed, keyword_init: true)

  def initialize(lock:, availability:, calendar_client:, event_id_key:)
    @lock = lock
    @availability = availability
    @calendar_client = calendar_client
    @event_id_key = event_id_key
  end

  # 仮押さえを作成する（active → held）。slots は [[Time, Time], ...]（件数・重複はルート側で検証済み）。
  # ロック内で最新の空きを再検証し、チケット遷移 → イベント作成×N の順で行う。
  def hold(token:, requester:, title:, slots:, holder_key:, now: Time.now)
    @lock.synchronize do
      return Result.new(status: :slot_taken) unless slots.all? { |s, e| @availability.slot_available?(s, e) }

      holds = slots.map { |s, e| hold_entry(token, s, e) }
      attrs = { "requester" => requester, "title" => title, "holder_key" => holder_key, "holds" => holds }
      return Result.new(status: :ticket_used) unless TicketStore.hold!(token, attrs: attrs, now: now)

      create_hold_events(token, requester, title, holds, now)
    end
  end

  # 仮押さえから 1 件を決定する（held → used）。決定イベントを確定形へ更新し、他の候補を削除する。
  # 仮押さえイベント自体が枠を専有しているため、空きの再検証は不要（他チケットと競合しない）。
  # send_invites: true ならゲストのオプトインとして参加者へ Google の標準招待メールを送る（既定は送らない）。
  def confirm(token:, slot_start:, attendees: [], video_url: "", request_meet: false, send_invites: false,
              now: Time.now)
    @lock.synchronize do
      attrs = attendees.empty? ? {} : { "attendees" => attendees }
      holds = TicketStore.confirm_hold!(token, slot_start: slot_start, attrs: attrs, now: now)
      return Result.new(status: :not_held) if holds.nil?

      chosen = holds.find { |h| h["slot_start"] == slot_start }
      ticket = TicketStore.find(token, now: now)
      meet_link, patch_failed = patch_chosen(chosen, ticket, video_url: video_url, attendees: attendees,
                                                             request_meet: request_meet,
                                                             send_invites: send_invites)
      failed = delete_events(holds - [chosen])
      Result.new(status: :ok, meet_link: meet_link, failed_deletes: failed, patch_failed: patch_failed)
    end
  end

  # 仮押さえから 1 件を取り除く（最後の 1 件なら cancelled）。対応するイベントも削除する。
  def remove(token:, slot_start:, now: Time.now)
    @lock.synchronize do
      removed = TicketStore.remove_hold!(token, slot_start: slot_start, now: now)
      return Result.new(status: :not_held) if removed.nil?

      Result.new(status: :ok, failed_deletes: delete_events([removed]))
    end
  end

  # 仮押さえをすべて取りやめて終了する（held → cancelled）。イベントもすべて削除する。
  def cancel(token:, now: Time.now)
    @lock.synchronize do
      holds = TicketStore.cancel_hold!(token, now: now)
      return Result.new(status: :not_held) if holds.nil?

      Result.new(status: :ok, failed_deletes: delete_events(holds))
    end
  end

  private

  # token とスロットから決定的に導くイベント ID を持つ hold エントリ。
  # 再試行で同じ ID になり、Google 側の一意制約（409）で重複作成を防ぐ（BookingService と同じ手法）。
  def hold_entry(token, starts_at, ends_at)
    digest = OpenSSL::HMAC.hexdigest("SHA256", @event_id_key, "#{token}:hold:#{starts_at.iso8601}")
    { "event_id" => "sukesan#{digest[0, 40]}",
      "slot_start" => starts_at.iso8601, "slot_end" => ends_at.iso8601 }
  end

  def create_hold_events(token, requester, title, holds, now)
    created = []
    holds.each do |entry|
      create_hold_event(entry, requester, title, now)
      created << entry
    end
    Result.new(status: :ok)
  rescue StandardError => e
    # 途中で失敗したら、作成済みイベントを取り消してチケットを active へ戻す（再試行できるようにする）。
    warn "[HoldService] 仮押さえの作成失敗: #{e.class}（作成済みイベントを取り消します）"
    rollback_created(token, created)
    Result.new(status: :api_failure)
  end

  def create_hold_event(entry, requester, title, now)
    @calendar_client.create_event(hold_event(entry, requester, title, now), id: entry["event_id"])
  rescue GoogleCalendarClient::Conflict
    # 決定的 ID が既に存在＝前回の試行で作成済み。成功として扱う（冪等な再試行）。
  end

  def hold_event(entry, requester, title, now)
    deadline = (now + TicketStatus::HOLD_TTL_SECONDS).getlocal.strftime("%Y-%m-%d %H:%M")
    Event.new(
      source: "google",
      title: "#{TITLE_PREFIX}#{title} - #{requester} (from 調整ツール)",
      starts_at: Time.iso8601(entry["slot_start"]),
      ends_at: Time.iso8601(entry["slot_end"]),
      all_day: false,
      description: "依頼者: #{requester}\n調整ツールの仮押さえです。#{deadline} までに 1 件に決定されます。"
    )
  end

  # 決定イベントを確定形（prefix 無しの件名・任意項目）へ更新する。戻り値は [meet_link, patch_failed]。
  # 更新に失敗しても決定（used への遷移）は取り消さない: 予定自体は正しい枠に存在しており、
  # 件名の [仮ブロック] 残りは運用で修正できる。ここで巻き戻すと二重決定の余地が生まれる方が害が大きい。
  def patch_chosen(chosen, ticket, video_url:, attendees:, request_meet:, send_invites:)
    description = "依頼者: #{ticket['requester']}"
    description += "\nビデオ会議: #{video_url}" unless video_url.to_s.empty?
    response = @calendar_client.patch_event(
      chosen["event_id"],
      summary: "#{ticket['title']} - #{ticket['requester']} (from 調整ツール)",
      description: description, attendees: attendees, request_meet: request_meet,
      send_updates: send_invites ? "all" : "none"
    )
    [request_meet ? GoogleCalendarClient.meet_link(response) : nil, false]
  rescue StandardError => e
    warn "[HoldService] 決定イベントの更新失敗: #{e.class}（[仮ブロック] の件名のまま残ります）"
    [nil, true]
  end

  # イベントを削除し、失敗した件数を返す（失敗分は [仮ブロック] として残る＝prefix で手動掃除可能）。
  def delete_events(entries)
    entries.count do |entry|
      @calendar_client.delete_event(entry["event_id"])
      false
    rescue StandardError => e
      warn "[HoldService] 仮押さえイベントの削除失敗: #{e.class}"
      true
    end
  end

  def rollback_created(token, created)
    delete_events(created)
    TicketStore.reactivate!(token)
  end
end
