# SUKESAN

SUKESAN（スケジュール管理ツール）は、Google カレンダーと連携したスケジュール調整ツールです。管理者が発行するワンタイム URL から、依頼者が空き時間を選んで予定を登録できます（1 件の登録のほか、最大 5 件の仮押さえにも対応）。補助機能として、Outlook 側にのみある予定を Google へ反映する Outlook 同期があります。

トップページ（`/`）は利用案内のみ。ワンタイム URL の発行・一覧・無効化は `/tickets`、カレンダー連携や調整時間の設定は `/settings`、Outlook 同期は `/sync` で行います（いずれも管理者専用。`/admin` が導線ハブ）。管理者は `ADMIN_PASSWORD_DIGEST` によるパスワードログイン、依頼者は有効なワンタイム URL のみでアクセスします（ログイン不要）。

## スケジュール登録（ワンタイム URL）

- 管理者が `/tickets` で発行する（要 Google 連携）。有効期限は発行時に 24 時間（既定）・72 時間・7 日から選び、1 回の登録で使用済みになる。一覧でステータス・有効期限を確認でき、コピー・手動無効化ができる。
- 依頼者は期間と必要時間を入力すると、営業時間・曜日・昼休憩の設定に基づく 30 分刻みの空き候補から枠を選んで登録できる。空き枠・入力値はサーバ側で再検証し、同一枠の二重予約は直列化と再確認で防ぐ。
- 任意項目: 参加者メールアドレス（主催者は自動追加）、ビデオ会議 URL、Google Meet 発行（URL 指定と併用不可）。会議リンクは登録した本人のブラウザにのみ表示される。
- 参加者への招待メールは既定では送らず、「参加者に招待メールを送る」をチェックしたときだけ Google の標準招待メールが届く。
- 「予定を非公開にする」をチェックすると `visibility: private` で登録され、カレンダーの共有相手には「予定あり」とだけ表示される（仮押さえでは作成時に指定し、決定後も維持される）。
- `SLACK_WEBHOOK_URL` を設定すると、予約・仮押さえ・決定・全取りやめを管理者の Slack へ通知する（通知が失敗しても操作自体は成功する）。
- `SLACK_MENTION` で通知にメンションを付けられる。`channel`（@channel）/ `here`（@here）/ メンバー ID（U… または W…）を指定でき、未設定・不正値ならメンションなし。

## 複数スケジュール仮押さえ

- 調整画面のタブから最大 5 件の日程を「[仮ブロック]」として仮押さえできる。仮押さえ後は同じ URL に 7 日間アクセスでき、1 件に決定すると残りは自動削除される（参加者・招待メール・会議 URL・Meet は決定時に指定）。
- 決定・削除と内容の閲覧は、仮押さえを行ったブラウザのみ可能。Cookie を失った場合は管理者が無効化して再発行する（無効化で残りの仮押さえイベントも削除される）。

## 設定（`/settings`）

- 営業時間・調整可能な曜日・昼休憩（時間帯と確保分数。0 分で無効）を設定する。時刻はすべて `APP_TIMEZONE`（既定 `Asia/Tokyo`）で解釈する。

## Outlook 同期

- Google・Outlook の両方を連携し、Outlook 側にのみある予定（突き合わせは「件名 + 開始 + 終了」）を選択して Google へ一方向で反映する。
- 取得範囲は日数（最大 180）か日付範囲で指定する。テストモードでは差分表示のみで反映しない。

## 他システム向け API

同一マシン上の別システム（チャットベースの AI エージェント等）から、空き時間の検索・予定の登録と取消・仮押さえ・ワンタイム URL の発行ができる JSON API です。`/settings` で API キーを発行したときだけ有効になります（キーが 1 つもなければ `/api/` 配下は 404）。

### 認証

- キーはシステム名と権限（read / write）を指定して発行する（64 文字・最大 20 件）。発行時に一度だけ表示され、サーバにはダイジェストのみ保存する。削除で即失効。
- read は参照のみ、write は参照に加えて書き込み（予定の登録・取消・仮押さえ・URL 発行）ができる。権限不足は 403 `insufficient_scope`。
- 接続元は loopback に限定（`REMOTE_ADDR` 判定）。認証は `Authorization: Bearer <キー>` ヘッダのみで、クエリでは渡せない。
- レート制限はキーごとに 60 回/分。書き込み（POST）にはさらに 10 回/分の制限が重なる。

### エンドポイント

| メソッド | パス | 権限 | 説明 |
|---|---|---|---|
| GET | `/api/v1/calendars/google/events` | read | 指定日（`date`・既定は当日）のイベント一覧 |
| GET | `/api/v1/availability` | read | 空き候補の検索（`start_date` / `end_date` / `duration_minutes`） |
| GET | `/api/v1/tickets` | read | チケット一覧（`status` / `page` / `per` で絞り込み） |
| GET | `/api/v1/tickets/:id` | read | チケット 1 件（write かつ未使用ならワンタイム URL も返す） |
| POST | `/api/v1/tickets` | write | ワンタイム URL の発行（`ttl_hours`） |
| POST | `/api/v1/tickets/:id/revoke` | write | チケットの無効化（仮押さえ中なら予定も削除） |
| POST | `/api/v1/bookings` | write | 確定した枠をカレンダーへ直接登録 |
| POST | `/api/v1/bookings/:id/cancel` | write | 登録済み予約の取消（`notify_attendees`） |
| POST | `/api/v1/holds` | write | 候補を最大 5 件「[仮ブロック]」として確保 |
| POST | `/api/v1/holds/:id/confirm` | write | 仮押さえから 1 件に決定し、他の候補を削除 |
| POST | `/api/v1/holds/:id/slots/delete` | write | 仮押さえの候補を 1 件だけ取り下げる |
| POST | `/api/v1/holds/:id/cancel` | write | 仮押さえの全取りやめ |

- 書き込みのリクエストボディは JSON（`Content-Type: application/json`・64KB 以内）。
- 日時は ISO8601（オフセット付き）で、時間帯は `{"starts_at": ..., "ends_at": ...}` に統一している。イベント一覧の各要素は `id` / `title` / `starts_at` / `ends_at` / `location` / `all_day`。
- `:id` はチケットの短縮 ID（`~xxxxxxxx`）で、一覧・発行の応答に含まれる。生のトークンは URL パス・クエリに載せない。
- API 経由の予約・仮押さえも内部でチケットを 1 枚使うため、管理画面 `/tickets` に並び、無効化で止められる。

### 使い方

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

### エラー

エラーは `{"error": {"code": "...", "message": "..."}}` 形式で返す。code は `invalid_params`（400）/ `invalid_date`（400）/ `unauthorized`（401）/ `forbidden`（403・loopback 以外）/ `insufficient_scope`（403・write 権限が必要）/ `not_found`（404）/ `slot_taken`（409・枠が埋まっている）/ `invalid_state`（409・チケットの状態が操作と合わない）/ `idempotency_conflict`（409・過去の予約で使った `Idempotency-Key`）/ `rate_limited`（429）/ `upstream_error`（502）/ `provider_not_connected`（503・未連携）。

### 注意・制約

- 操作できるのは直近 30 日に発行したチケットだけ（短縮 ID で引ける範囲）。それより古い予約は API から取り消せない。
- 削除できるのは sukesan 経由で作った予定だけ。イベント ID はクライアントから受け取らず、チケットに保存した値のみを使う。
- `Idempotency-Key` はシステム名ごとにスコープされ、同じキーの再送には登録済みの内容をそのまま返す（内容の一致は検証しない）。会議リンクは永続化しないため、再送の応答では `meet_link` が null になる。
- 取り消した予約と同じ `Idempotency-Key` は再利用できない（Google が削除した予定の ID を再利用できないため、409 `idempotency_conflict` になる）。取消後に同じ枠を登録し直すときは新しいキーを指定する。
- write キーは管理者相当の権限を持つ。依頼者がブラウザで作った仮押さえも、holder の照合なしに API から決定・削除できる。
- 書き込みは監査ログに残し、`SLACK_WEBHOOK_URL` を設定していれば「API 経由: システム名」を添えて Slack へ通知する。

## セットアップ

```bash
bundle install
cp .env.example .env   # 各項目の説明は .env.example 内のコメント参照
```

- Google OAuth（必須）: Google Cloud Console で Calendar API を有効化し、OAuth クライアント ID（ウェブ）を作成。リダイレクト URI に `http://localhost:3000/auth/google/callback` を登録。スコープは `calendar.events` と `userinfo.email`。
- Microsoft（Outlook 同期を使う場合のみ）: Azure でアプリ登録し、リダイレクト URI `http://localhost:3000/auth/microsoft/callback` を登録。委任アクセス許可 `Calendars.Read` と `offline_access` を付与。
- 管理者パスワードは `bin/admin_password_digest` で bcrypt ダイジェストを生成し、`ADMIN_PASSWORD_DIGEST` に設定する。
- `TOKEN_ENCRYPTION_KEY` は保存トークン・チケットの暗号鍵。変更・紛失すると既存の保存データは復号できない。

## 起動・運用

```bash
bin/server start|stop|restart|status   # run はサービス管理用のフォアグラウンド起動
bin/server install|uninstall           # macOS: ログイン時の自動起動を有効化 / 解除
```

- ブラウザで <http://localhost:3000>（ポートは `PORT` で変更可）。
- macOS で常駐させるには `bin/server install`。`deploy/com.sukesan.server.plist` をパス置換して `~/Library/LaunchAgents/` に設置し、launchd に登録する（ログイン時に自動起動・落ちたら再起動）。以後 `start` / `stop` / `restart` / `status` は launchctl に委譲され、未設置なら従来どおり PID ファイルで管理する。解除は `bin/server uninstall`。
- ログは `log/` 配下で週次ローテーション。アクセスログはトークン・OAuth code をマスクし、監査ログは操作を 1 行 JSON で記録する。`LOG_TO_STDOUT=true` で stdout へ切替（コンテナ向け）。
- OS サービス登録用テンプレートは `deploy/`（macOS は `com.sukesan.server.plist`＝`bin/server install` が使う、Linux は systemd の `sukesan.service`。どちらも `bin/server run` を起動コマンドにする）。
- `APP_ENV=production` で本番ハードニング（HTTPS 必須リダイレクト・Secure Cookie・HSTS 等）が有効になる。HTTPS は前段プロキシで終端し、`APP_TRUST_PROXY=true` を設定する。

## データストア（file / firestore）

`STORE_BACKEND` で永続化の実装を切り替える。どちらもトークン・チケットは `TOKEN_ENCRYPTION_KEY` で暗号化して保存する。

- `file`（既定）: `data/` 配下のローカルファイル（0600・Atomic 書き込み）。単一ホスト前提で、開発・VM 運用向け。チケットは約 30 日で自動削除。
- `firestore`: Cloud Run など向け。チケットの状態遷移はトランザクションで処理し、物理削除は `purge_at` の TTL ポリシーに委ねる。単一インスタンス運用（`max-instances=1`）が前提。

## Cloud Run デプロイ

1. Firestore（Native モード）を有効化し、`tickets` コレクションの `purge_at` に TTL ポリシーを設定する。
2. 秘密情報（`SESSION_SECRET` / `TOKEN_ENCRYPTION_KEY` / `ADMIN_PASSWORD_DIGEST` / Google・MS のクレデンシャル）を Secret Manager に登録する。`TOKEN_ENCRYPTION_KEY` はデプロイをまたいで固定し、別途バックアップする。
3. デプロイ:

   ```bash
   gcloud run deploy sukesan \
     --source . \
     --region asia-northeast1 \
     --allow-unauthenticated \
     --max-instances 1 \
     --set-env-vars APP_ENV=production,STORE_BACKEND=firestore,APP_TRUST_PROXY=true,APP_BASE_URL=https://YOUR_DOMAIN,APP_TIMEZONE=Asia/Tokyo,LOG_TO_STDOUT=true \
     --set-secrets SESSION_SECRET=SESSION_SECRET:latest,TOKEN_ENCRYPTION_KEY=TOKEN_ENCRYPTION_KEY:latest,ADMIN_PASSWORD_DIGEST=ADMIN_PASSWORD_DIGEST:latest,GOOGLE_CLIENT_ID=GOOGLE_CLIENT_ID:latest,GOOGLE_CLIENT_SECRET=GOOGLE_CLIENT_SECRET:latest
   ```

4. 独自ドメインはロードバランサを使わず Cloud Run のドメインマッピングで割り当て、`APP_BASE_URL` と OAuth の redirect_uri を本番ドメインに合わせる。`--max-instances 1` は同一枠の二重予約防止の前提。

## 開発

```bash
bundle exec rspec          # テスト
bundle exec rubocop        # Lint（-a で自動修正）
```

- Firestore アダプタの spec はエミュレータ（`FIRESTORE_EMULATOR_HOST`）がある場合のみ実行される。`docker compose up --build` でアプリ＋エミュレータの本番相当も起動できる。
- CSP 維持のため、ERB に inline `<script>` や inline イベントハンドラは書かず、JavaScript は `public/*.js` に分離して読み込む。
- 構成: ルートと起動設定は `app.rb`、Web ヘルパは `helpers/`、ドメインロジックは `lib/`、ビューは `views/`、テストは `spec/`。

## 注意・制約

- ワンタイム URL を知る人は期限内・未使用なら登録できるため、共有先に注意する。
- 反映先は Google の `primary` カレンダー。本番は HTTPS 必須。
