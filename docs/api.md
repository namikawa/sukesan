# 外部連携 API リファレンス（/api/v1）

同一マシン上の別システム（チャットベースの AI エージェント等）から SUKESAN を操作するための JSON API です。この文書は連携先を実装するための完全なリファレンスです。SUKESAN 本体の機能・セットアップは [README](../README.md) を参照してください。

## 概要

この API でできることは 5 つです。

- 空き候補の検索（管理者カレンダーの空き時間を、営業時間・曜日・祝日・昼休憩の設定に従って算出する）
- 予定の直接登録と取消（相手との調整が済んだ枠を管理者カレンダーへ登録する／登録した予定を取り消す）
- 仮押さえ（複数候補を `[仮ブロック]` として確保し、あとで 1 件に決定する）
- ワンタイム URL（チケット）の発行と無効化（依頼者に枠を選んでもらう場合）
- チケットの参照（発行済み URL・予約・仮押さえの状態確認）

予約・仮押さえ・ワンタイム URL はすべて内部的に同じ「チケット」で表現されます。API 経由で登録した予約も管理画面 `/tickets` に並び、無効化・取消で巻き戻せます。

ベース URL は `http://127.0.0.1:<PORT>`（`PORT` の既定は 3000）です。パスにバージョン（`v1`）を含み、バージョン交渉の仕組みはありません。

## 有効化と接続

- `/settings` で API キーを 1 つ以上発行したときだけ有効になります。発行済みキーが 1 つもなければ `/api/` 配下のすべてのリクエストが 404 `not_found` を返します（API 自体が存在しない扱い）。
- 接続元は loopback（`127.0.0.1` / `::1`）に限定されます。判定には偽装できない `REMOTE_ADDR` を使うため、`X-Forwarded-For` では回避できません。loopback 以外は 403 `forbidden` です。
- 前段プロキシ経由でリクエストが届く環境（Cloud Run など）では `REMOTE_ADDR` が loopback にならないため、この API は利用できません。同一マシン上の別プロセス向けの機能です。

## 認証と権限

認証は `Authorization: Bearer <キー>` ヘッダのみです。クエリ・ボディでキーを渡すことはできません。

```
Authorization: Bearer 0123456789abcdef...（64 文字）
```

### キーの発行と失効

キーは管理画面 `/settings` で発行します。

| 項目 | 内容 |
|---|---|
| システム名（ラベル） | 必須・50 文字以内・`:` を含められない・重複不可。レート制限・監査ログ・冪等キーのスコープ単位になる |
| 権限（スコープ） | `read` / `write` から選ぶ（既定 `read`） |
| キー本体 | サーバが生成する 64 文字の 16 進文字列 |
| 登録数 | 最大 20 件 |

サーバには SHA-256 ダイジェストのみを保存し、キー本体は発行直後の画面で一度だけ表示します（再表示不可）。紛失した場合は削除して再発行してください。`/settings` でキーを削除すると即座に認証不可になります。

照合はダイジェスト同士の定数時間比較です。一致するキーが無い・ヘッダが無い場合は 401 `unauthorized` を返し、監査ログに `api_auth_failed` を記録します。

### スコープ

| スコープ | できること |
|---|---|
| `read` | 参照系（GET）のみ |
| `write` | 参照系に加えて書き込み系（POST）も可能。`read` を包含する |

書き込み権限の判定はエンドポイントごとではなく「POST は一律 `write` が必要」という形で課しています。`read` キー（およびスコープ導入前に発行され `scope` を持たないキー。fail-closed で `read` 扱い）で POST すると 403 `insufficient_scope` を返し、監査ログに `api_scope_denied` を記録します。

`write` キーは管理者相当の権限を持ちます。詳細は「制約・運用上の注意」を参照してください。

### チェックの順序

エラーの切り分けのため、判定は次の順に行われます。

1. 発行済みキーが 0 件 → 404 `not_found`
2. 接続元が loopback でない → 403 `forbidden`
3. キーが一致しない → 401 `unauthorized`
4. 参照・書き込み共通のレート制限を超過 → 429 `rate_limited`
5. POST かつ `read` キー → 403 `insufficient_scope`
6. POST の追加レート制限を超過 → 429 `rate_limited`
7. 各エンドポイントの入力検証 → 400
8. Google カレンダー未連携 → 503（入力検証の後に判定する）

## 共通仕様

### リクエスト

- 書き込み系（POST）のボディは JSON オブジェクトで、`Content-Type: application/json` を付けます。フォーム形式（`application/x-www-form-urlencoded`）は JSON として解釈できないため 400 `invalid_params` になります。
- ボディの上限は 64KB（65,536 バイト）です。超過は 400 `invalid_params`。
- 空のボディは `{}`（すべて既定値）として扱います。トップレベルが配列などオブジェクト以外の場合は 400 `invalid_params`。
- CSRF トークンは不要です（`/api/` 配下は検証対象外。Cookie・セッションを認証に使わないため CSRF が成立しない）。
- 冪等キーは `Idempotency-Key` ヘッダで渡します（`POST /api/v1/bookings` のみ有効）。

### レスポンス

- 成功・エラーとも `Content-Type: application/json` と `Cache-Control: no-store`（および `Pragma: no-cache`）が付きます。
- エラーは常に次のエンベロープです。`message` は日本語の説明文で、内容は将来変わり得ます。分岐は `code` と HTTP ステータスで行ってください。

```json
{"error": {"code": "invalid_params", "message": "title は 100 文字以内の文字列で指定してください（必須）。"}}
```

- 例外的に、想定外のサーバエラー（500）だけは JSON エンベロープではなくプレーンテキストを返します。パースに失敗し得るため、ステータスコードで判定してください。

### 日時の扱い

- 日時は ISO8601、時間帯は `{"starts_at": ..., "ends_at": ...}` のオブジェクトで統一しています。
- サーバのタイムゾーンは `APP_TIMEZONE`（既定 `Asia/Tokyo`）に固定されています。応答の日時はこのタイムゾーンのオフセット付き（例 `2026-08-04T10:00:00+09:00`）です。ただし保存済みの日時（`created_at` / `used_at` / `slot` / `holds` など）は保存時の表記をそのまま返します。
- 入力の日時はオフセット付きを推奨します。オフセットを省略すると `APP_TIMEZONE` のローカル時刻として解釈され、`Z`（UTC）表記も受け付けます。時間帯の照合はエポック秒で行うため表記の違いは吸収されますが、後述の `slot_starts_at` だけは文字列の完全一致で照合するため、応答で返った `starts_at` をそのまま送り返してください。
- 日付のみのパラメータ（`date` / `start_date` / `end_date`）は `YYYY-MM-DD` 形式です。

### チケット識別子

- API 上のチケット識別子（パスの `:id`）は `~xxxxxxxx` 形式の短縮 ID です。トークンの HMAC-SHA256 の先頭 8 桁（16 進）で、アクセスログ・監査ログに現れる ID と同一なので運用時に相関できます。
- 短縮 ID から生トークンは復元できません。生トークン（ワンタイム URL）を返すのは次の 2 か所だけです。
  - `POST /api/v1/tickets` の応答（依頼者へ渡すため）
  - `GET /api/v1/tickets/:id` の応答（`write` キーかつ状態が `active` のときのみ）
- 逆引きの対象は直近 30 日に発行されたチケットに限られます（「制約・運用上の注意」参照）。

### レート制限

| 対象 | 上限 | 単位 |
|---|---|---|
| すべてのリクエスト | 60 回 / 60 秒 | API キーのシステム名（ラベル）ごと |
| POST（書き込み系） | 追加で 10 回 / 60 秒 | API キーのシステム名ごと |

- 数え方は 60 秒のスライディングウィンドウです。POST は両方の枠を消費し、GET は書き込み枠を消費しません。
- IP ではなくキー単位で数えるため、キーを分けると枠も分かれます。
- 超過は 429 `rate_limited`。`Retry-After` は付かないため、60 秒待って再試行してください。
- カウンタはプロセス内メモリに保持します（再起動でリセット）。

## 使い方の例

空き候補を探して登録し、あとで取り消す流れ:

```bash
KEY="発行した API キー"; BASE=http://127.0.0.1:3000; AUTH="Authorization: Bearer $KEY"

curl -H "$AUTH" "$BASE/api/v1/availability?start_date=2026-08-04&end_date=2026-08-08&duration_minutes=30"

# Idempotency-Key を付けると、タイムアウト後に再送しても二重登録にならない
curl -X POST -H "$AUTH" -H "Content-Type: application/json" -H "Idempotency-Key: yamada-0804" \
  -d '{"slot": {"starts_at": "2026-08-04T10:00:00+09:00", "ends_at": "2026-08-04T10:30:00+09:00"},
       "requester": "山田様", "title": "打ち合わせ",
       "attendees": ["yamada@example.com"], "send_invites": true}' \
  "$BASE/api/v1/bookings"
# => {"id":"~a1b2c3d4","status":"used","slot":{...},"meet_link":null}

curl -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"notify_attendees": true}' "$BASE/api/v1/bookings/~a1b2c3d4/cancel"
```

依頼者に選んでもらうワンタイム URL の発行と、候補を押さえてから決める仮押さえ:

```bash
curl -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"ttl_hours": 72}' "$BASE/api/v1/tickets"
# => {"id":"~...","url":"http://127.0.0.1:3000/t/<token>","status":"active",...}

curl -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"slots": [{"starts_at": "2026-08-04T10:00:00+09:00", "ends_at": "2026-08-04T10:30:00+09:00"},
                 {"starts_at": "2026-08-05T14:00:00+09:00", "ends_at": "2026-08-05T14:30:00+09:00"}],
       "requester": "山田様", "title": "打ち合わせ"}' "$BASE/api/v1/holds"

curl -X POST -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"slot_starts_at": "2026-08-04T10:00:00+09:00"}' "$BASE/api/v1/holds/~a1b2c3d4/confirm"
```

## チケットの状態と操作の対応

チケットは次の状態を取ります。`status` は保存値と時刻から導出され、`expires_at` は期限を持つ状態（`active` / `held`）のときだけ値が入ります。

| status | 意味 | 期限 |
|---|---|---|
| `active` | 発行済み・未使用。ワンタイム URL として利用できる | `created_at` + `ttl_hours`（24 / 72 / 168 時間） |
| `held` | 仮押さえ中。`[仮ブロック]` の予定がカレンダーに存在する | `held_at` + 7 日 |
| `used` | 予約が確定している（直接予約・仮押さえからの決定・依頼者による登録） | なし（終端） |
| `cancelled` | 予約の取消、または仮押さえの全取りやめで終了した | なし（終端） |
| `revoked` | 管理者・API が無効化した | なし（終端） |
| `expired` | `active` / `held` のまま期限を過ぎた | なし |

遷移は次のとおりです。

```
（発行）        → active
active + 予約   → used          POST /api/v1/bookings（内部で 1 枚発行して即消費）/ 依頼者の登録
active + 仮押さえ → held         POST /api/v1/holds（同上）/ 依頼者の仮押さえ
active/held + 無効化 → revoked   POST /api/v1/tickets/:id/revoke
held + 決定     → used          POST /api/v1/holds/:id/confirm
held + 全取りやめ → cancelled    POST /api/v1/holds/:id/cancel
held + 最後の候補を削除 → cancelled  POST /api/v1/holds/:id/slots/delete
used + 取消     → cancelled     POST /api/v1/bookings/:id/cancel
active/held + 時間経過 → expired
```

状態ごとに受け付ける操作は次のとおりです。条件に合わない状態への操作は 409 `invalid_state` です。

| 操作 | 受け付ける状態 |
|---|---|
| `GET /api/v1/tickets/:id` | すべて（`url` を含めるのは `active` かつ `write` キーのときだけ） |
| `POST /api/v1/tickets/:id/revoke` | `active` / `held` |
| `POST /api/v1/bookings/:id/cancel` | `used` かつイベント ID を保存しているもの |
| `POST /api/v1/holds/:id/confirm` | `held` |
| `POST /api/v1/holds/:id/slots/delete` | `held` |
| `POST /api/v1/holds/:id/cancel` | `held` |

保存データが破損・改ざんされて未知の状態値を持つチケットは `invalid` として扱い、いずれの操作も受け付けません（fail-closed）。`invalid` は一覧の `status` 絞り込みでは指定できません。

## エンドポイント

全 12 本です。

| メソッド | パス | 権限 | 説明 |
|---|---|---|---|
| GET | [`/api/v1/calendars/google/events`](#get-apiv1calendarsgoogleevents) | read | 指定日（`date`・既定は当日）のイベント一覧 |
| GET | [`/api/v1/availability`](#get-apiv1availability) | read | 空き候補の検索（`start_date` / `end_date` / `duration_minutes`） |
| GET | [`/api/v1/tickets`](#get-apiv1tickets) | read | チケット一覧（`status` / `page` / `per` で絞り込み） |
| GET | [`/api/v1/tickets/:id`](#get-apiv1ticketsid) | read | チケット 1 件（write かつ未使用ならワンタイム URL も返す） |
| POST | [`/api/v1/tickets`](#post-apiv1tickets) | write | ワンタイム URL の発行（`ttl_hours`） |
| POST | [`/api/v1/tickets/:id/revoke`](#post-apiv1ticketsidrevoke) | write | チケットの無効化（仮押さえ中なら予定も削除） |
| POST | [`/api/v1/bookings`](#post-apiv1bookings) | write | 確定した枠をカレンダーへ直接登録 |
| POST | [`/api/v1/bookings/:id/cancel`](#post-apiv1bookingsidcancel) | write | 登録済み予約の取消（`notify_attendees`） |
| POST | [`/api/v1/holds`](#post-apiv1holds) | write | 候補を最大 5 件 `[仮ブロック]` として確保 |
| POST | [`/api/v1/holds/:id/confirm`](#post-apiv1holdsidconfirm) | write | 仮押さえから 1 件に決定し、他の候補を削除 |
| POST | [`/api/v1/holds/:id/slots/delete`](#post-apiv1holdsidslotsdelete) | write | 仮押さえの候補を 1 件だけ取り下げる |
| POST | [`/api/v1/holds/:id/cancel`](#post-apiv1holdsidcancel) | write | 仮押さえの全取りやめ |

以下、パラメータ表の「必須」は必須項目、それ以外は任意項目です。

### GET /api/v1/calendars/google/events

必要な権限: `read`。指定日の Google カレンダー（`primary`）のイベント一覧を返します。

| 名前 | 型 | 必須 | 制約・既定値 |
|---|---|---|---|
| `date` | string（クエリ） | | `YYYY-MM-DD`。省略時は `APP_TIMEZONE` での今日 |

対象期間はその日の 0:00 から翌日 0:00（ローカルタイム）です。繰り返し予定は個別の予定へ展開され、ページネーションは内部で辿ります。

成功（200）:

```json
{
  "date": "2026-08-04",
  "events": [
    {
      "id": "abc123def456",
      "title": "朝会",
      "starts_at": "2026-08-04T10:00:00+09:00",
      "ends_at": "2026-08-04T11:00:00+09:00",
      "location": "会議室 A",
      "all_day": false
    }
  ]
}
```

| フィールド | 説明 |
|---|---|
| `date` | 対象日（リクエストの `date`、省略時は当日） |
| `events[].id` | Google カレンダーのイベント ID |
| `events[].title` | 件名。Google 側に件名が無ければ null |
| `events[].starts_at` / `ends_at` | 開始・終了。終日予定はその日の 0:00 になる |
| `events[].location` | 場所。未設定なら null |
| `events[].all_day` | 終日予定か |

エラー:

| code | HTTP | 条件 |
|---|---|---|
| `invalid_date` | 400 | `date` が `YYYY-MM-DD` として解釈できない（このエンドポイントのみ `invalid_params` ではなく `invalid_date`） |
| `provider_not_connected` | 503 | Google カレンダーが未連携、またはトークンの更新に失敗している |
| `upstream_error` | 502 | Google API 呼び出しが失敗した |

### GET /api/v1/availability

必要な権限: `read`。指定期間・所要時間の空き候補を返します。依頼者向け画面の検索と同じロジック・制約です。

| 名前 | 型 | 必須 | 制約・既定値 |
|---|---|---|---|
| `start_date` | string（クエリ） | 必須 | `YYYY-MM-DD` |
| `end_date` | string（クエリ） | 必須 | `YYYY-MM-DD` |
| `duration_minutes` | integer（クエリ） | 必須 | 15 分単位の正の整数（15 / 30 / 45 …） |

算出のルール:

- 対象は営業日（`/settings` の調整可能な曜日に一致し、かつ日本の祝日でない日）のみ。
- 期間内の営業日が 5 日を超える場合は先頭 5 日で打ち切り、`capped` を `true` にします。期間の走査自体も最大 366 日で止まります。
- 候補は営業時間内・30 分刻みで、既存の予定と重ならない枠だけを返します。終日予定は時間を専有しないものとして扱い、候補を塞ぎません。
- 現在時刻 + 5 分より手前に始まる枠（過去・直前）は除外します。
- 営業日が 1 日も無い期間は `days` が空配列（`capped` は `false`）になります。

成功（200）:

```json
{
  "duration_minutes": 30,
  "capped": false,
  "days": [
    {
      "date": "2026-08-04",
      "slots": [
        {"starts_at": "2026-08-04T09:00:00+09:00", "ends_at": "2026-08-04T09:30:00+09:00", "lunch_warning": false},
        {"starts_at": "2026-08-04T12:00:00+09:00", "ends_at": "2026-08-04T12:30:00+09:00", "lunch_warning": true}
      ]
    }
  ]
}
```

| フィールド | 説明 |
|---|---|
| `duration_minutes` | リクエストの所要時間（分） |
| `capped` | 営業日 5 日で打ち切ったか |
| `days[].date` | 日付 |
| `days[].slots[]` | その日の空き候補（開始時刻順） |
| `slots[].lunch_warning` | その枠を取ると昼休憩の連続確保（`/settings` の時間帯・分数）が崩れることを示す印。候補自体は選択できる |

候補はスナップショットです。予約・仮押さえの時点でサーバが空きを取り直して再検証するため、間に別の予定が入れば 409 `slot_taken` になります。

エラー:

| code | HTTP | 条件 |
|---|---|---|
| `invalid_params` | 400 | `start_date` / `end_date` の欠落・形式不正、`duration_minutes` の欠落・非数値・15 分の倍数でない・0 以下 |
| `provider_not_connected` | 503 | Google カレンダーが未連携 |
| `upstream_error` | 502 | Google API 呼び出しが失敗した |

### GET /api/v1/tickets

必要な権限: `read`。チケットの一覧を新しい順（発行日時の降順）で返します。管理画面 `/tickets` の API 版で、予約・仮押さえも内部チケットとしてここに並びます。対象は直近 30 日に発行されたものだけです。

| 名前 | 型 | 必須 | 制約・既定値 |
|---|---|---|---|
| `status` | string（クエリ） | | `active` / `held` / `used` / `revoked` / `cancelled` / `expired` のいずれか。省略時は絞り込みなし |
| `page` | integer（クエリ） | | 既定 1。1 未満・範囲外は端へクランプする |
| `per` | integer（クエリ） | | `10` / `20` / `50` / `100` のみ。許可外・省略は 10 |

成功（200）:

```json
{
  "tickets": [
    {
      "id": "~a1b2c3d4",
      "status": "used",
      "created_at": "2026-08-04T09:00:00+09:00",
      "expires_at": null,
      "ttl_hours": 24,
      "requester": "山田様",
      "title": "打ち合わせ",
      "slot": {"starts_at": "2026-08-05T10:00:00+09:00", "ends_at": "2026-08-05T10:30:00+09:00"},
      "used_at": "2026-08-04T09:05:00+09:00",
      "holds": null
    }
  ],
  "page": 1,
  "total_pages": 1
}
```

| フィールド | 説明（null になる条件） |
|---|---|
| `id` | 短縮 ID |
| `status` | 上表のいずれか |
| `created_at` | 発行日時 |
| `expires_at` | 有効期限。`active` は `created_at` + `ttl_hours`、`held` は `held_at` + 7 日。それ以外の状態（`used` / `cancelled` / `revoked` / `expired`）は null |
| `ttl_hours` | 発行時に選んだ有効期間（24 / 72 / 168）。未保存の古いチケットは 24 として扱う |
| `requester` | 依頼者名。予約・仮押さえの内容が未登録なら null |
| `title` | 予定名。同上 |
| `slot` | 確定した時間帯（`{starts_at, ends_at}`）。未確定（`active` / `held` / 仮押さえの全取りやめ後）は null |
| `used_at` | 予約が確定した日時。未確定なら null |
| `holds` | 仮押さえ中の候補（`[{starts_at, ends_at}]`・開始時刻順）。`held` 以外は null |

生トークン・ワンタイム URL・仮押さえの Google イベント ID・holder_key は含めません。`total_pages` は最小 1 で、該当が無い場合 `tickets` は空配列です。

エラー:

| code | HTTP | 条件 |
|---|---|---|
| `invalid_params` | 400 | `status` が許可値以外 |

### GET /api/v1/tickets/:id

必要な権限: `read`。チケット 1 件の詳細を返します。フィールドは一覧の各要素と同じです。

| 名前 | 型 | 必須 | 制約・既定値 |
|---|---|---|---|
| `:id` | string（パス） | 必須 | 短縮 ID（`~xxxxxxxx`） |

`write` キーかつ状態が `active` のときだけ、ワンタイム URL を `url` フィールドで追加します（依頼者へ URL を渡し直すユースケース向け）。`read` キー、または `active` 以外の状態では `url` キー自体が存在しません。

成功（200）:

```json
{
  "id": "~a1b2c3d4",
  "status": "active",
  "created_at": "2026-08-04T09:00:00+09:00",
  "expires_at": "2026-08-05T09:00:00+09:00",
  "ttl_hours": 24,
  "requester": null,
  "title": null,
  "slot": null,
  "used_at": null,
  "holds": null,
  "url": "http://127.0.0.1:3000/t/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
}
```

エラー:

| code | HTTP | 条件 |
|---|---|---|
| `not_found` | 404 | 該当する短縮 ID のチケットが無い（直近 30 日の範囲外を含む） |

### POST /api/v1/tickets

必要な権限: `write`。ワンタイム URL を発行します。生トークンを含む URL を返すのはこの応答と、`write` キーでの詳細取得（`active` のときのみ）だけです。

| 名前 | 型 | 必須 | 制約・既定値 |
|---|---|---|---|
| `ttl_hours` | integer | | `24` / `72` / `168` のみ（数値文字列も可）。省略・null・許可外はすべて 24 に落とす（fail-closed） |

成功（201）:

```json
{
  "id": "~a1b2c3d4",
  "url": "http://127.0.0.1:3000/t/xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "status": "active",
  "ttl_hours": 72,
  "created_at": "2026-08-04T09:00:00+09:00",
  "expires_at": "2026-08-07T09:00:00+09:00"
}
```

URL のホスト部は `APP_BASE_URL`（本番は必須。未設定の開発環境ではリクエストから組み立てる）に従います。監査ログに `ticket_create` を記録します（Slack 通知はありません）。

エラー:

| code | HTTP | 条件 |
|---|---|---|
| `invalid_params` | 400 | ボディが JSON オブジェクトでない・64KB 超過 |
| `insufficient_scope` | 403 | `read` キー |
| `rate_limited` | 429 | レート制限超過 |

### POST /api/v1/tickets/:id/revoke

必要な権限: `write`。発行済みチケットを無効化します（URL の漏えい・放置時の kill switch）。仮押さえ中だった場合は残っている `[仮ブロック]` の予定も削除します。

| 名前 | 型 | 必須 | 制約・既定値 |
|---|---|---|---|
| `:id` | string（パス） | 必須 | 短縮 ID |

リクエストボディは不要です（送っても読みません）。

成功（200）:

```json
{"id": "~a1b2c3d4", "status": "revoked", "failed_deletes": 0}
```

| フィールド | 説明 |
|---|---|
| `failed_deletes` | 削除できなかった `[仮ブロック]` の件数。仮押さえ中でなければ 0。Google 未連携の場合は候補の全件が失敗として数えられる（無効化自体は成立する） |

エラー:

| code | HTTP | 条件 |
|---|---|---|
| `not_found` | 404 | 該当する短縮 ID のチケットが無い |
| `invalid_state` | 409 | 状態が `active` / `held` 以外（使用済み・取消済み・無効化済み・期限切れ・破損） |
| `insufficient_scope` | 403 | `read` キー |

監査ログに `ticket_revoke` を記録します（Slack 通知はありません）。

### POST /api/v1/bookings

必要な権限: `write`。確定済みの枠を管理者カレンダーへ直接登録します。内部でチケットを 1 枚発行して即消費するため、登録した予約はチケット一覧に `used` で並び、`POST /api/v1/bookings/:id/cancel` で取り消せます。

| 名前 | 型 | 必須 | 制約・既定値 |
|---|---|---|---|
| `slot` | object | 必須 | `{"starts_at": ISO8601, "ends_at": ISO8601}` |
| `requester` | string | 必須 | 依頼者名。前後の空白を除いて 1〜100 文字 |
| `title` | string | 必須 | 予定名。前後の空白を除いて 1〜100 文字 |
| `attendees` | `array<string>` | | 参加者メールアドレス。最大 50 件。空要素と重複は除去する。主催者（連携時に取得した管理者のメール）は自動で先頭に加わる |
| `video_url` | string | | ビデオ会議 URL。`http://` / `https://` で始まる 2048 文字以内。`request_meet` との同時指定は不可。説明欄に載せ、チケットには保存しない |
| `request_meet` | boolean | | 既定 false。true で Google Meet のリンクを発行する |
| `send_invites` | boolean | | 既定 false。true のときだけ参加者へ Google の標準招待メールを送る（`sendUpdates=all`） |
| `private_event` | boolean | | 既定 false。true で `visibility: private` を付ける（カレンダーの共有相手には「予定あり」とだけ表示される） |
| `Idempotency-Key` | string（ヘッダ） | | 128 文字以内。詳細は「冪等性」を参照 |

真偽値の項目は JSON の `true` / `false` だけを受け付けます。`"1"` や `"true"` などの文字列は 400 です。

登録される予定は次の内容になります。

- 件名: `<title> - <requester> (from 調整ツール)`
- 説明: `依頼者: <requester>`（`video_url` を指定した場合は改行して `ビデオ会議: <video_url>`）
- カレンダー: `primary`

枠の妥当性（営業日・営業時間・30 分刻みの候補との一致・所要時間が 15 分の倍数・現在時刻 + 5 分以降・他の予定と重ならないこと）は、ロック内で空きを取り直して再検証します。クライアントが提示した値をそのまま信用しません。

成功（201）:

```json
{
  "id": "~a1b2c3d4",
  "status": "used",
  "slot": {"starts_at": "2026-08-05T10:00:00+09:00", "ends_at": "2026-08-05T10:30:00+09:00"},
  "meet_link": "https://meet.google.com/abc-defg-hij"
}
```

| フィールド | 説明 |
|---|---|
| `id` | 発行された内部チケットの短縮 ID。取消・参照に使う |
| `status` | 常に `used` |
| `slot` | 登録した時間帯 |
| `meet_link` | 発行された Google Meet の URL。`request_meet` を指定しなかった場合・Google が返さなかった場合・冪等キーによるリプレイ応答では null。チケットには永続化しないため、この応答でしか取得できない |

エラー:

| code | HTTP | 条件 |
|---|---|---|
| `invalid_params` | 400 | ボディの形式、各項目の欠落・型・上限違反、参加者の形式・件数、URL の形式、`request_meet` との排他、`Idempotency-Key` の長さ超過 |
| `insufficient_scope` | 403 | `read` キー |
| `slot_taken` | 409 | 再検証で枠が使えない（他の予定と衝突・営業日/営業時間外・過去や直前・候補に一致しない） |
| `idempotency_conflict` | 409 | 過去に同じ `Idempotency-Key` で登録し、取り消した予約がある（「冪等性」参照） |
| `upstream_error` | 502 | Google への登録が失敗した |
| `provider_not_connected` | 503 | Google カレンダーが未連携 |
| `rate_limited` | 429 | レート制限超過 |

入力検証エラー・未連携ではチケットを発行しません。登録に失敗した場合の内部チケットは `active` で残さず無効化します（一覧にゴミを残さないため）。監査ログは成功時 `booking_created` / 失敗時 `booking_failed`、Slack 通知は成功時のみです。

### POST /api/v1/bookings/:id/cancel

必要な権限: `write`。確定済みの予約（`used`）を取り消し、Google の予定を削除します（`used` → `cancelled`）。削除対象のイベント ID はチケットに保存した値だけを使い、クライアントからは受け取りません。

| 名前 | 型 | 必須 | 制約・既定値 |
|---|---|---|---|
| `:id` | string（パス） | 必須 | 短縮 ID |
| `notify_attendees` | boolean | | 既定 false。true で Google から参加者へキャンセル通知を送る（`sendUpdates=all`）。招待メールを送った予約を取り消すときに指定する |

成功（200）:

```json
{"id": "~a1b2c3d4", "status": "cancelled", "event_deleted": true}
```

| フィールド | 説明 |
|---|---|
| `event_deleted` | Google の予定を削除できたか。Google 側に既に無い（404 / 410）場合も true。false のときはカレンダーに予定が残っているため手動で削除する（取消自体は成立している） |

取消後もチケットには登録内容（`requester` / `title` / `slot`）が残るため、一覧では `cancelled` として内容付きで参照できます（仮押さえの全取りやめによる `cancelled` は `slot` を持ちません）。

エラー:

| code | HTTP | 条件 |
|---|---|---|
| `not_found` | 404 | 該当する短縮 ID のチケットが無い |
| `invalid_params` | 400 | ボディの形式、`notify_attendees` が真偽値でない |
| `invalid_state` | 409 | `used` でない（未使用・仮押さえ中・既に取消済み・無効化済み）、またはイベント ID を保存していない古い予約 |
| `provider_not_connected` | 503 | Google カレンダーが未連携（予定を消せないままチケットだけ取消済みにしないよう、遷移の前に判定する） |
| `insufficient_scope` | 403 | `read` キー |

監査ログに `booking_cancelled` を記録し、Slack へ通知します（削除に失敗した場合は手動削除を促す注記が付きます）。

### POST /api/v1/holds

必要な権限: `write`。複数の候補を `[仮ブロック]` として確保します。内部でチケットを 1 枚発行して `held` にするため、決定・取りやめ・無効化はチケットの短縮 ID で行います。

| 名前 | 型 | 必須 | 制約・既定値 |
|---|---|---|---|
| `slots` | `array<object>` | 必須 | `{"starts_at", "ends_at"}` の配列。1〜5 件。時間帯が互いに重なるものは不可 |
| `requester` | string | 必須 | 依頼者名。前後の空白を除いて 1〜100 文字 |
| `title` | string | 必須 | 予定名。前後の空白を除いて 1〜100 文字 |
| `private_event` | boolean | | 既定 false。true で候補の全件を `visibility: private` で作成する。決定後も維持される |

参加者・招待メール・ビデオ会議 URL・Meet は仮押さえ時には指定できません（決定時に指定します）。各候補の枠は作成時にロック内で再検証します（`POST /api/v1/bookings` と同じ条件）。

作成される予定は次の内容です。

- 件名: `[仮ブロック] <title> - <requester> (from 調整ツール)`
- 説明: 依頼者名と、決定期限（仮押さえから 7 日）の案内

成功（201）:

```json
{
  "id": "~a1b2c3d4",
  "status": "held",
  "expires_at": "2026-08-11T09:00:00+09:00",
  "slots": [
    {"starts_at": "2026-08-05T10:00:00+09:00", "ends_at": "2026-08-05T10:30:00+09:00"},
    {"starts_at": "2026-08-06T14:00:00+09:00", "ends_at": "2026-08-06T14:30:00+09:00"}
  ]
}
```

| フィールド | 説明 |
|---|---|
| `expires_at` | 仮押さえの期限（仮押さえ実行から 7 日）。チケットの `ttl_hours` ではない |
| `slots` | 確保した候補（開始時刻順）。決定・個別削除で使う `slot_starts_at` はここで返る `starts_at` をそのまま渡す |

エラー:

| code | HTTP | 条件 |
|---|---|---|
| `invalid_params` | 400 | `slots` の欠落・非配列・0 件・6 件以上・要素の形式不正・日時形式不正・時間帯の重複、`requester` / `title` / `private_event` の不正 |
| `insufficient_scope` | 403 | `read` キー |
| `slot_taken` | 409 | いずれかの候補が確保できない（再検証で不可） |
| `upstream_error` | 502 | `[仮ブロック]` の作成が失敗した（途中まで作成した予定は削除して巻き戻す） |
| `provider_not_connected` | 503 | Google カレンダーが未連携 |
| `rate_limited` | 429 | レート制限超過 |

失敗時の内部チケットは `active` で残さず無効化します。監査ログに `hold_created`、Slack へ通知します。

### POST /api/v1/holds/:id/confirm

必要な権限: `write`。仮押さえから 1 件を決定します（`held` → `used`）。選んだ予定は件名の `[仮ブロック] ` を外して確定形へ更新し、他の候補は削除します。

| 名前 | 型 | 必須 | 制約・既定値 |
|---|---|---|---|
| `:id` | string（パス） | 必須 | 短縮 ID |
| `slot_starts_at` | string | 必須 | 決定する候補の開始時刻。応答の `slots[].starts_at` と完全一致する文字列を渡す（文字列一致で照合するため表記を変えてはいけない） |
| `attendees` | `array<string>` | | `POST /api/v1/bookings` と同じ（最大 50 件・主催者を自動追加） |
| `video_url` | string | | 同じ（`request_meet` と排他） |
| `request_meet` | boolean | | 既定 false |
| `send_invites` | boolean | | 既定 false |

`private_event` はここでは指定できません（仮押さえの作成時に指定した設定が維持されます）。決定時は仮押さえの予定が既に枠を専有しているため、空きの再検証は行いません。

成功（200）:

```json
{
  "id": "~a1b2c3d4",
  "status": "used",
  "slot": {"starts_at": "2026-08-05T10:00:00+09:00", "ends_at": "2026-08-05T10:30:00+09:00"},
  "meet_link": null,
  "patch_failed": false,
  "failed_deletes": 0
}
```

| フィールド | 説明 |
|---|---|
| `slot` | 決定した時間帯 |
| `meet_link` | `request_meet` 指定時に発行された URL（それ以外は null）。永続化しないためこの応答でしか取得できない |
| `patch_failed` | 決定した予定の更新（件名の `[仮ブロック]` 除去・参加者追加など）に失敗したか。true でも決定自体は成立しており、件名が `[仮ブロック]` のまま残る |
| `failed_deletes` | 削除できなかった他候補の件数。残った予定は件名の prefix で手動掃除できる |

エラー:

| code | HTTP | 条件 |
|---|---|---|
| `not_found` | 404 | 短縮 ID が不明、または `slot_starts_at` がチケットの保存候補に無い |
| `invalid_state` | 409 | 対象が `held` でない（未使用・決定済み・取りやめ済み・期限切れ）。決定の直前に他経路で状態が変わった場合も含む |
| `invalid_params` | 400 | ボディの形式、`slot_starts_at` の欠落・型不正、任意項目の不正 |
| `provider_not_connected` | 503 | Google カレンダーが未連携 |
| `insufficient_scope` | 403 | `read` キー |

部分失敗（件名更新・他候補の削除）は 502 ではなく 200 + フラグで伝えます。監査ログに `hold_confirmed`、Slack へ通知します。

### POST /api/v1/holds/:id/slots/delete

必要な権限: `write`。仮押さえから候補を 1 件だけ取り下げ、対応する `[仮ブロック]` の予定を削除します。最後の 1 件を取り下げるとチケットは `cancelled` で終了します。

| 名前 | 型 | 必須 | 制約・既定値 |
|---|---|---|---|
| `:id` | string（パス） | 必須 | 短縮 ID |
| `slot_starts_at` | string | 必須 | 取り下げる候補の開始時刻（応答の `starts_at` と完全一致する文字列） |

成功（200）:

```json
{
  "id": "~a1b2c3d4",
  "status": "held",
  "slots": [{"starts_at": "2026-08-06T14:00:00+09:00", "ends_at": "2026-08-06T14:30:00+09:00"}],
  "failed_deletes": 0
}
```

| フィールド | 説明 |
|---|---|
| `status` | 候補が残っていれば `held`、最後の 1 件を取り下げたら `cancelled` |
| `slots` | 残っている候補（開始時刻順）。終了した場合は空配列 |
| `failed_deletes` | 削除できなかった予定の件数。候補からは外れるが、カレンダーには `[仮ブロック]` のまま残る |

エラー:

| code | HTTP | 条件 |
|---|---|---|
| `not_found` | 404 | 短縮 ID が不明、または `slot_starts_at` が保存候補に無い |
| `invalid_state` | 409 | 対象が `held` でない |
| `invalid_params` | 400 | ボディの形式、`slot_starts_at` の欠落・型不正 |
| `provider_not_connected` | 503 | Google カレンダーが未連携 |
| `insufficient_scope` | 403 | `read` キー |

監査ログに `hold_deleted` を記録します。調整途中の操作のため Slack 通知はしません（依頼者の画面からの個別削除と同じ扱い）。

### POST /api/v1/holds/:id/cancel

必要な権限: `write`。仮押さえをすべて取りやめてチケットを終了します（`held` → `cancelled`）。`[仮ブロック]` の予定も全件削除します。

| 名前 | 型 | 必須 | 制約・既定値 |
|---|---|---|---|
| `:id` | string（パス） | 必須 | 短縮 ID |

リクエストボディは不要です（送っても読みません）。

成功（200）:

```json
{"id": "~a1b2c3d4", "status": "cancelled", "failed_deletes": 0}
```

`failed_deletes` は削除できなかった `[仮ブロック]` の件数です（取りやめ自体は成立します）。

エラー:

| code | HTTP | 条件 |
|---|---|---|
| `not_found` | 404 | 短縮 ID が不明 |
| `invalid_state` | 409 | 対象が `held` でない（二重の取りやめを含む） |
| `provider_not_connected` | 503 | Google カレンダーが未連携 |
| `insufficient_scope` | 403 | `read` キー |

監査ログに `hold_cancelled`、Slack へ通知します。

## 冪等性（Idempotency-Key）

`POST /api/v1/bookings` は任意ヘッダ `Idempotency-Key` に対応します。タイムアウト後の再送で予定が二重に登録されるのを防ぐための仕組みです。

```
Idempotency-Key: yamada-20260805-1000
```

### 意味論

- スコープ: キーは API キーのシステム名（ラベル）ごとに分かれます。別システムが偶然同じキー文字列を使っても、他システムの予約のリプレイ応答を受け取ることはありません。
- 長さ: 128 文字以内（超過は 400）。前後の空白は除かれ、空文字は未指定と同じ扱いです。
- リプレイの対象: 同じキーで登録され、状態が `used` のチケットだけです。見つかった場合は新規登録せず、保存内容から 200（201 ではない）で応答します。このとき監査ログ・Slack 通知は行いません。
- リプレイ応答の `meet_link` は常に null です。会議 URL はチケットに永続化しないため、初回の応答でしか取得できません。
- 内容の一致は検証しません。同じキーで違う `slot` や `title` を送っても、最初に登録した内容がそのまま返ります。キーは 1 回の登録操作に 1 つ割り当ててください。
- 失敗したキーは再利用できます。登録が 502 で終わった内部チケットは無効化されるためリプレイ対象にならず、同じキーでの再試行がそのまま新規登録として通ります。
- 取消済みの予約とのキー再利用は不可です。Google は削除した予定の ID を再利用できないため、取り消した予約と同じキーで登録すると 409 `idempotency_conflict` になります（予定が無いのに成功を返さないための設計）。取消後に同じ枠を登録し直す場合は新しいキーを指定してください。
- 同一キーの同時実行では、2 本目が 409 `idempotency_conflict` になり得ます（リプレイ検索と登録の間で競合した場合）。予定は 1 件のままで二重登録は起きません。逐次のリトライはリプレイ応答で吸収されます。

### 応答を受け取れなかった場合

ネットワークのタイムアウトなどで応答を受け取れなくても、Google 側では予定が作成されていることがあります。この場合サーバは失敗と決める前に予定の存在を 1 回だけ確認し、次の両方を満たすときだけ登録成功（201）として扱います。

- 予定が生きている（削除されていない）
- 時間帯がリクエストの `slot` と一致する

条件を満たさない・確認自体が失敗した場合は 502 を返します。その後同じキーで再試行すれば、Google 側の一意制約により 409 `idempotency_conflict` へ収束します。

### キーを指定しない場合

毎回新規の予約として登録します（リトライ保護なし）。この場合の Google イベント ID はチケットのトークン由来で、同じチケットの再試行でしか衝突しないため、Google の 409 は「前回の試行で作成済み」＝成功として扱われます。

## エラーリファレンス

| code | HTTP | 意味 | 主な発生箇所 |
|---|---|---|---|
| `invalid_params` | 400 | 入力検証エラー（`message` に具体的な理由） | 全エンドポイントのパラメータ・ボディ検証 |
| `invalid_date` | 400 | `date` の形式が不正 | `GET /api/v1/calendars/google/events` のみ |
| `unauthorized` | 401 | `Authorization: Bearer` が無い・一致するキーが無い | 全エンドポイント（監査ログ `api_auth_failed`） |
| `forbidden` | 403 | 接続元が loopback でない | 全エンドポイント |
| `insufficient_scope` | 403 | `write` 権限が必要 | すべての POST（監査ログ `api_scope_denied`） |
| `not_found` | 404 | API キーが未発行、短縮 ID が不明、`slot_starts_at` が保存候補に無い、未定義のパス・メソッド | 全エンドポイント |
| `slot_taken` | 409 | 空き再検証で枠が使えない | `POST /api/v1/bookings`、`POST /api/v1/holds` |
| `invalid_state` | 409 | チケットの状態が操作と合わない | `revoke`、`bookings/:id/cancel`、`holds/:id/*` |
| `idempotency_conflict` | 409 | 過去の予約で使った `Idempotency-Key` | `POST /api/v1/bookings` |
| `rate_limited` | 429 | レート制限超過（60 回/分、POST は追加で 10 回/分） | 全エンドポイント |
| `upstream_error` | 502 | Google API 呼び出しの失敗（詳細は応答に出さない） | events / availability / bookings / holds |
| `provider_not_connected` | 503 | Google カレンダーが未連携、またはトークン更新に失敗している | 全エンドポイント（Google を使う操作） |

想定外のサーバエラー（500）だけは JSON エンベロープではなくプレーンテキストを返します。

## 制約・運用上の注意

- 操作できるのは直近 30 日に発行されたチケットだけです。短縮 ID からチケットを引ける範囲がこれに一致するため、それより古い予約は API から参照・取消できません（`404 not_found`）。
- 削除できるのは SUKESAN 経由で作成した予定だけです。イベント ID はクライアントから受け取らず、チケットに保存した値のみを使うため、任意の予定を API から消すことはできません。
- `write` キーは管理者相当の権限を持ちます。依頼者がブラウザで作った仮押さえも、holder（仮押さえを行ったブラウザ）の照合なしに API から決定・削除できます。API はセッションを持たないためこの照合ができない、という前提での設計です。
- 部分失敗は成功応答のフィールドで伝えます。カレンダー操作が一部失敗しても、チケットの遷移（決定・取消・取りやめ）は成立させたうえで次のフィールドで通知します。
  - `patch_failed`: 決定した予定の更新に失敗（件名が `[仮ブロック]` のまま残る）
  - `failed_deletes`: 削除できなかった `[仮ブロック]` の件数
  - `event_deleted`: 取消した予約の予定を削除できたか
  - いずれの場合も残った予定は管理者が手動で削除します。`[仮ブロック]` の prefix で探せます。
- 書き込み操作は監査ログに 1 行 JSON で記録します（`ticket_create` / `ticket_revoke` / `booking_created` / `booking_failed` / `booking_cancelled` / `hold_created` / `hold_confirmed` / `hold_deleted` / `hold_cancelled`）。対象はチケットの短縮 ID とキーのシステム名（`via=api:<システム名>`）で、依頼者名・予定名などは記録しません。
- `SLACK_WEBHOOK_URL` を設定している場合、予約の登録・予約の取消・仮押さえの作成・決定・全取りやめを管理者の Slack へ通知します（文面に「API 経由: `<システム名>`」が付きます）。チケットの発行・無効化と候補の個別削除、冪等キーによるリプレイ応答は通知しません。通知はベストエフォートで、失敗しても操作自体は成功します。
- 反映先は Google の `primary` カレンダーです。時刻はすべて `APP_TIMEZONE`（既定 `Asia/Tokyo`）で解釈します。
- 同一枠の二重予約防止は単一インスタンス運用を前提にしたロックで実現しています。レート制限のカウンタもプロセス内メモリです。
