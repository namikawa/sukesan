# frozen_string_literal: true

RSpec.describe "Outlook 同期 /check・/sync" do
  let(:google_hash) { { "access_token" => "g", "expires_at" => 4_102_444_800 } }
  let(:ms_hash) { { "access_token" => "m", "expires_at" => 4_102_444_800 } }
  let(:settings) do
    {
      "business_start" => "09:00", "business_end" => "18:00", "business_days" => [1, 2, 3, 4, 5],
      "lunch_start" => "11:00", "lunch_end" => "14:00", "lunch_minutes" => 60, "sync_window_days" => 30
    }
  end
  let(:ms_event) do
    {
      "id" => "1", "subject" => "会議",
      "start" => { "dateTime" => "2026-07-01T01:00:00.000" },
      "end" => { "dateTime" => "2026-07-01T02:00:00.000" }, "isAllDay" => false
    }
  end

  before do
    login_admin!
    allow(TokenStore).to receive(:load).and_return(google_hash)
    allow(TokenStore).to receive(:load).with(:microsoft).and_return(ms_hash)
    allow(SettingsStore).to receive(:load).and_return(settings)
    allow(SettingsStore).to receive(:save)
    stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
      .to_return(status: 200, body: { "items" => [] }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, %r{graph\.microsoft\.com/v1\.0/me/calendarView})
      .to_return(status: 200, body: { "value" => [] }.to_json, headers: { "Content-Type" => "application/json" })
  end

  describe "POST /check" do
    it "日数指定（当日起点）でチェックし、日数を既定として保存する" do
      post "/check", authenticity_token: csrf_token, range_mode: "days", sync_window_days: "30"
      expect(last_response.status).to eq(302)
      expect(SettingsStore).to have_received(:save).with(hash_including(sync_window_days: 30))
    end

    it "日数が 180 を超えるとエラーで取得・保存しない" do
      post "/check", authenticity_token: csrf_token, range_mode: "days", sync_window_days: "181"
      expect(last_response.status).to eq(302)
      expect(SettingsStore).not_to have_received(:save)
      expect(a_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})).not_to have_been_made
    end

    it "日付範囲指定でチェックできる（日数は保存しない）" do
      post "/check", authenticity_token: csrf_token, range_mode: "range",
                     start_date: "2026-07-01", end_date: "2026-07-10"
      expect(last_response.status).to eq(302)
      expect(SettingsStore).not_to have_received(:save)
    end

    it "日付範囲が 180 日を超えるとエラーで取得しない" do
      post "/check", authenticity_token: csrf_token, range_mode: "range",
                     start_date: "2026-07-01", end_date: "2027-07-01"
      expect(last_response.status).to eq(302)
      expect(a_request(:get, %r{graph\.microsoft\.com/v1\.0/me/calendarView})).not_to have_been_made
    end

    it "開始 > 終了はエラー" do
      post "/check", authenticity_token: csrf_token, range_mode: "range",
                     start_date: "2026-07-10", end_date: "2026-07-01"
      expect(last_response.status).to eq(302)
      expect(a_request(:get, %r{graph\.microsoft\.com/v1\.0/me/calendarView})).not_to have_been_made
    end
  end

  # GET /sync・POST /sync は取得範囲（セッション保存）から差分を都度再計算する。
  describe "差分の表示と反映" do
    let(:selection) { ms_event["id"] } # 選択は一意な external_id（Outlook の Graph ID）で行う
    # Google 側に Outlook と同一キーの予定を返すスタブ（＝差分から除外される）。
    let(:google_has_event) do
      {
        "items" => [{
          "id" => "g1", "summary" => "会議",
          "start" => { "dateTime" => "2026-07-01T01:00:00Z" },
          "end" => { "dateTime" => "2026-07-01T02:00:00Z" }
        }]
      }
    end

    before do
      stub_request(:get, %r{graph\.microsoft\.com/v1\.0/me/calendarView})
        .to_return(status: 200, body: { "value" => [ms_event] }.to_json,
                   headers: { "Content-Type" => "application/json" })
    end

    it "テストモードのチェックは差分プレビューのみで同期ボタンを出さない" do
      post "/check", authenticity_token: csrf_token, range_mode: "days", sync_window_days: "30", test_mode: "1"
      get "/sync"
      expect(last_response.body).to include("テストモード")
      expect(last_response.body).to include("会議")
      expect(last_response.body).not_to include("選択したイベントを Google に同期")
    end

    it "テストモード後の POST /sync は Google へ反映しない" do
      create = stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
               .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
      post "/check", authenticity_token: csrf_token, range_mode: "days", sync_window_days: "30", test_mode: "1"
      post "/sync", authenticity_token: csrf_token, selected: [selection]
      expect(last_response.status).to eq(302)
      expect(create).not_to have_been_requested
    end

    it "チェック直後の GET /sync は結果を表示し、再表示（更新）では結果を残さない" do
      post "/check", authenticity_token: csrf_token, range_mode: "days", sync_window_days: "30"
      get "/sync"
      expect(last_response.body).to include("会議") # 初回表示は結果あり
      get "/sync"
      expect(last_response.body).not_to include("会議") # 更新・再表示では消える
    end

    it "POST /sync は選択したイベントを Google に作成する" do
      create = stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
               .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
      post "/check", authenticity_token: csrf_token, range_mode: "days", sync_window_days: "30"
      post "/sync", authenticity_token: csrf_token, selected: [selection]
      expect(create).to have_been_requested.once
    end

    it "Outlook 本文を Google イベントの説明（description）として作成する" do
      with_body = ms_event.merge("body" => { "contentType" => "text", "content" => "議題: 予算確認" })
      stub_request(:get, %r{graph\.microsoft\.com/v1\.0/me/calendarView})
        .to_return(status: 200, body: { "value" => [with_body] }.to_json,
                   headers: { "Content-Type" => "application/json" })
      stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
        .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })

      post "/check", authenticity_token: csrf_token, range_mode: "days", sync_window_days: "30"
      post "/sync", authenticity_token: csrf_token, selected: [selection]

      expect(
        a_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
          .with { |req| JSON.parse(req.body)["description"] == "議題: 予算確認" }
      ).to have_been_made
    end

    it "既に Google にあるイベントは再計算で差分から外れ、作成しない（冪等）" do
      create = stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
               .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
      stub_request(:get, %r{googleapis\.com/calendar/v3/calendars/primary/events})
        .to_return(status: 200, body: google_has_event.to_json, headers: { "Content-Type" => "application/json" })
      post "/check", authenticity_token: csrf_token, range_mode: "days", sync_window_days: "30"
      post "/sync", authenticity_token: csrf_token, selected: [selection]
      expect(create).not_to have_been_requested
    end

    it "同一件名・同一時刻でも external_id 単位で選べ、選んだ 1 件だけ作成する" do
      dup = ms_event.merge("id" => "2") # 件名・開始・終了は同じ（match_key 衝突）だが別イベント
      stub_request(:get, %r{graph\.microsoft\.com/v1\.0/me/calendarView})
        .to_return(status: 200, body: { "value" => [ms_event, dup] }.to_json,
                   headers: { "Content-Type" => "application/json" })
      create = stub_request(:post, %r{googleapis\.com/calendar/v3/calendars/primary/events})
               .to_return(status: 200, body: "{}", headers: { "Content-Type" => "application/json" })
      post "/check", authenticity_token: csrf_token, range_mode: "days", sync_window_days: "30"
      post "/sync", authenticity_token: csrf_token, selected: ["1"] # 片方だけ選択

      expect(create).to have_been_requested.once
    end
  end
end
