# SUKESAN

SUKESAN（スケジュール管理ツール）は、Google カレンダーと連携したスケジュール調整ツールです。管理者が発行するワンタイム URL から、依頼者が空き時間を選んで予定を登録できます（1 件の登録のほか、最大 5 件の仮押さえにも対応）。補助機能として、Outlook 側にのみある予定を Google へ反映する Outlook 同期（管理者専用）があります。

トップページ（`/`）は利用案内のみ。ワンタイム URL の発行・一覧・無効化は `/tickets`、カレンダー連携や調整時間の設定は `/settings` で行います（いずれも管理者専用。`/admin` が各ツールへの導線ハブ）。

## 画面と権限

| URL | 権限 | 内容 |
| --- | --- | --- |
| `GET /` | 公開 | 利用案内ページ |
| `GET /t/:token` | トークン | 調整ページ（空き候補の検索・登録・仮押さえの決定/削除） |
| `POST /schedule` | トークン | 空き枠を 1 件登録し、トークンを使用済みにする |
| `POST /hold` ほか | トークン | 複数日程の仮押さえ・決定・削除（決定・削除は仮押さえを行ったブラウザのみ） |
| `GET /admin` | 管理者 | 管理者トップ（各ツールへの導線） |
| `GET /tickets`・`POST /tickets` ほか | 管理者 | ワンタイム URL の発行・一覧・無効化 |
| `GET /settings`・`POST /settings` ほか | 管理者 | カレンダー連携・調整時間などの設定 |
| `GET /sync` ほか | 管理者 | Outlook → Google 同期 |
| `/auth/google`・`/auth/microsoft` | 管理者 | OAuth 連携 |

権限の意味: 公開 = 認証不要。トークン = 有効なワンタイム URL が必要（ログイン不要）。管理者 = `ADMIN_PASSWORD_DIGEST` でのログインが必要（未認証はその場でログイン画面を表示）。

## スケジュール登録（ワンタイム URL）

- 管理者が `/tickets` で発行する（要 Google 連携）。発行から 24 時間有効・1 回の登録で使用済みになる。無効な URL へのアクセスは案内ページ（HTTP 410）を返す。一覧でステータスと登録内容を確認でき、有効な URL はコピー・手動無効化ができる。
- 依頼者は期間と必要時間を入力すると、営業時間・曜日・昼休憩の設定に基づく 30 分刻みの空き候補（最大 5 営業日分）から枠を選んで登録できる。登録予定名は `[予定名] - [依頼者名] (from 調整ツール)`。
- 任意項目: 参加者メールアドレス（複数可。参加者として登録するが招待メールは送らない。主催者は自動追加）、ビデオ会議 URL、Google Meet リンクの発行（URL 指定と Meet 発行は併用不可）。会議リンクは登録した本人のブラウザにのみ表示される。
- 空き枠・入力値はサーバ側で再検証し、二重登録・同一枠の二重予約は直列化と再確認で防ぐ。レート制限は同一 IP につき登録・仮押さえ操作 5 回/分、空き時間検索 10 回/分（超過は 429）。
- `SLACK_WEBHOOK_URL` を設定すると、ゲストの予約・仮押さえ・決定・全取りやめを管理者の Slack へ通知する（依頼者名・件名・日時を含む。通知はベストエフォートで、失敗しても操作自体は成功する）。

## 複数スケジュール仮押さえ

- 調整画面のタブから最大 5 件の日程を「[仮ブロック]」としてカレンダーに仮押さえできる。仮押さえ後は同じ URL に 7 日間アクセスでき、1 件に決定すると残りの仮押さえは自動削除される（参加者・ビデオ会議 URL・Google Meet は決定時に指定）。
- 決定・個別削除・全削除と内容の閲覧は、仮押さえを行ったブラウザのみ可能（URL だけを知る第三者には案内のみ表示）。ブラウザの Cookie を失うと操作できなくなるため、その場合は管理者が無効化して新しい URL を再発行する。
- 管理者は `/tickets` で仮押さえ中のチケット（日程・残件数・期限）を確認でき、無効化すると残りの仮押さえイベントもカレンダーから削除される。

## 設定（`/settings`）

- 営業時間・調整可能な曜日・昼休憩（時間帯と確保分数。0 分で無効）を設定する。
- 昼休憩の確保が難しくなる候補には「（ランチタイム）」の注意書きを表示する。件名に「ランチ」「らんち」「lunch」を含む予定が当日の 10:00〜16:00 に既にある日は、その予定を昼休憩とみなし表示しない。
- 時刻はすべて `APP_TIMEZONE`（既定 `Asia/Tokyo`）で解釈・表示する。

## Outlook 同期

Google・Outlook の両方を連携し、Outlook 側にのみある予定を抽出して、選択分を Google（`primary`）へ一方向で反映します。突き合わせは「件名 + 開始 + 終了」。

- 取得範囲は `/sync` で「日数（当日 0:00 起点・最大 180）」か「日付範囲（最大 180 日）」を指定する。日数は前回値を既定として記憶する。
- テストモードでは差分の一覧表示のみで Google には反映しない（誤適用防止のためサーバ側でも反映を拒否）。

## 他システム向け API

同一マシン上で動く別システムから、連携済みの Google カレンダーの「特定の日のイベント一覧」を取得できる JSON API です。既定では無効で、`/settings` で API キーを発行したときだけ有効になります。

- API キーは `/settings` の「他システム向け API キー」でシステム名を指定して発行する（64 文字・最大 20 件）。キーは発行時に一度だけ表示され、再表示はできない（サーバには SHA-256 ダイジェストのみ保存）。控え忘れた場合は削除して再発行する。
- 発行済みのキーが 1 つもなければ `/api/` 配下はすべて 404（API 自体が存在しない扱い）。キーを削除するとそのキーは即座に失効する。
- 接続元は loopback（`127.0.0.1` / `::1`）に限定する。判定は `REMOTE_ADDR` で行い、`X-Forwarded-For` には影響されない。
- 認証は `Authorization: Bearer <キー>` ヘッダのみ（クエリでのキー受け渡しは受け付けない）。レート制限はキー（システム名）ごとに 60 回/分。
- すべての応答は `Content-Type: application/json`・`Cache-Control: no-store`。

エンドポイント: `GET /api/v1/calendars/google/events`

- クエリ `date`（任意・`YYYY-MM-DD`）。省略時は `APP_TIMEZONE`（既定 `Asia/Tokyo`）での当日。対象期間はその日の 0:00 から翌日 0:00。

成功時（200）のレスポンス例:

```json
{
  "date": "2026-07-10",
  "events": [
    {
      "id": "abc123",
      "title": "朝会",
      "starts_at": "2026-07-10T10:00:00+09:00",
      "ends_at": "2026-07-10T11:00:00+09:00",
      "location": "会議室 A",
      "all_day": false
    }
  ]
}
```

エラー時は `{"error": {"code": "...", "message": "..."}}` を返す。

| HTTP | code | 意味 |
| --- | --- | --- |
| 400 | `invalid_date` | `date` の形式が不正 |
| 401 | `unauthorized` | キーがない・不正 |
| 403 | `forbidden` | loopback 以外からの接続 |
| 404 | `not_found` | API が無効（発行済みキーなし）または存在しないパス |
| 429 | `rate_limited` | レート制限超過 |
| 502 | `upstream_error` | Google API の呼び出しに失敗 |
| 503 | `provider_not_connected` | Google カレンダーが未連携 |

使用例:

```bash
curl -H "Authorization: Bearer <キー>" \
  "http://127.0.0.1:3000/api/v1/calendars/google/events?date=2026-07-10"
```

## セットアップ

```bash
bundle install
cp .env.example .env   # 値を設定（各項目の説明は .env.example 内のコメント参照）
```

OAuth クライアントの用意:

- Google（必須）: Google Cloud Console で Calendar API を有効化し、OAuth クライアント ID（ウェブ）を作成。リダイレクト URI に `http://localhost:3000/auth/google/callback` を登録。スコープは `https://www.googleapis.com/auth/calendar.events` と `https://www.googleapis.com/auth/userinfo.email`（OAuth 同意画面にも追加）。
- Microsoft（Outlook 同期を使う場合のみ）: Azure でアプリ登録し、リダイレクト URI `http://localhost:3000/auth/microsoft/callback` を登録。委任アクセス許可 `Calendars.Read` と `offline_access` を付与。

主な環境変数（一覧と説明は `.env.example`）:

- `ADMIN_PASSWORD_DIGEST`: 管理者パスワードの bcrypt ダイジェスト。`bin/admin_password_digest` で生成し、シングルクォートで囲んで設定する。未設定だとログイン不可。
- `SESSION_SECRET`（64 文字以上）と `TOKEN_ENCRYPTION_KEY`: セッションと保存トークン・チケットの鍵。本番では必須。`TOKEN_ENCRYPTION_KEY` を変更・紛失すると既存の保存データは復号できない。
- `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` と、Outlook 用の `MS_CLIENT_ID` / `MS_CLIENT_SECRET` / `MS_TENANT_ID`。
- `APP_BASE_URL`: 公開 URL。OAuth の redirect_uri やチケット URL の生成に使う。本番（`APP_ENV=production`）では必須。
- `SLACK_WEBHOOK_URL`: 任意。設定すると、ゲストの予約・仮押さえ・決定・全取りやめを管理者の Slack へ通知する（未設定なら通知しない）。

## 起動・運用

```bash
bin/server start     # 起動（バックグラウンド）
bin/server stop      # 停止
bin/server restart   # 再起動
bin/server status    # 状態確認
bin/server run       # フォアグラウンド（サービス管理用）
```

- ブラウザで <http://localhost:3000>（ポートは `PORT` で変更可）。直接起動する場合は `bundle exec ruby app.rb`。
- ログは `log/` 配下。アクセスログ `access.log`（ワンタイム URL のトークン・OAuth code はマスクして記録。週次ローテーション）、監査ログ `audit.log`（ログイン成否・URL 発行/無効化・設定変更・連携・予約・仮押さえ操作を 1 行 JSON で記録）、プロセス出力 `server.log`。`LOG_TO_STDOUT=true` で stdout へ切替（コンテナ向け）。
- OS サービス登録用テンプレートは `deploy/`（systemd: `sukesan.service` / launchd: `com.sukesan.server.plist`）。`bin/server run` を起動コマンドにし、`__APP_DIR__` 等を置換して登録する。
- `APP_ENV=production` で本番ハードニング（HTTPS 必須リダイレクト・Cookie の Secure 化・エラー秘匿・HSTS）が有効になる。HTTPS は前段プロキシで終端し、`APP_TRUST_PROXY=true` を設定する。

## データストア（file / firestore）

`STORE_BACKEND` で永続化の実装を切り替える（設定・OAuth トークン・チケット）。どちらの実装でも、トークンとチケットは `TOKEN_ENCRYPTION_KEY` で暗号化して保存する（Firestore では制御・クエリ用の最小限のフィールドのみ平文）。

- `file`（既定）: `data/` 配下のローカルファイル（0600・Atomic 書き込み）。flock で直列化するため単一ホスト前提。開発・VM 運用向け。内訳は `settings.json`（設定）、`google_token.json` / `microsoft_token.json`（OAuth トークン）、`tickets/`（ワンタイム URL。ISO 週ごとに分割し、約 30 日で自動削除）。
- `firestore`: Google Cloud Firestore（Cloud Run など向け）。チケットの状態遷移はトランザクションで処理し、物理削除は `purge_at` フィールドの TTL ポリシーに委ねる。同一スロットの二重予約防止はプロセス内ロックに依存するため、単一インスタンス運用（`max-instances=1`）が前提。

## Cloud Run デプロイ

コンテナはプレーン HTTP で `$PORT`（Cloud Run は既定 8080）を listen し、TLS はプラットフォームが終端する前提。手順の概略:

1. Firestore（Native モード）を有効化し、`tickets` コレクションの `purge_at` フィールドに TTL ポリシーを設定する。
2. 秘密情報を Secret Manager に登録: `SESSION_SECRET` / `TOKEN_ENCRYPTION_KEY` / `ADMIN_PASSWORD_DIGEST` / `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` /（Outlook 同期を使うなら）`MS_CLIENT_ID` / `MS_CLIENT_SECRET` / `MS_TENANT_ID`。`TOKEN_ENCRYPTION_KEY` はデプロイをまたいで固定し、別途バックアップする。
3. ビルドしてデプロイ:

   ```bash
   gcloud run deploy sukesan \
     --source . \
     --region asia-northeast1 \
     --allow-unauthenticated \
     --max-instances 1 \
     --set-env-vars APP_ENV=production,STORE_BACKEND=firestore,APP_TRUST_PROXY=true,APP_BASE_URL=https://YOUR_DOMAIN,APP_TIMEZONE=Asia/Tokyo,LOG_TO_STDOUT=true \
     --set-secrets SESSION_SECRET=SESSION_SECRET:latest,TOKEN_ENCRYPTION_KEY=TOKEN_ENCRYPTION_KEY:latest,ADMIN_PASSWORD_DIGEST=ADMIN_PASSWORD_DIGEST:latest,GOOGLE_CLIENT_ID=GOOGLE_CLIENT_ID:latest,GOOGLE_CLIENT_SECRET=GOOGLE_CLIENT_SECRET:latest
   ```

4. 独自ドメインはロードバランサを使わず Cloud Run のドメインマッピング（または Firebase Hosting）で割り当て、`APP_BASE_URL` と OAuth の redirect_uri を本番ドメインに合わせる。

備考: `--max-instances 1` は同一スロットの二重予約を防ぐための前提。ログは stdout 経由で Cloud Logging に収集される。レート制限はインスタンス内メモリのため複数インスタンス間では共有されない。

## 開発

```bash
bundle exec rspec          # テスト
bundle exec rubocop        # Lint（-a で自動修正）
```

- Firestore アダプタの spec はエミュレータ（`FIRESTORE_EMULATOR_HOST`）がある場合のみ実行される。`docker compose up --build` でアプリ＋エミュレータの本番相当（<http://localhost:3000>）も起動できる。
- CI（GitHub Actions）で rubocop / rspec / Firestore アダプタ / bundler-audit / secret scan を実行する。
- CSP（`script-src 'self'` / `style-src 'self'`）を維持するため、ERB に inline `<script>` や inline イベントハンドラを書かず、JavaScript は `public/*.js` に分離して `<script src>` で読み込む。
- 構成: ルートと起動設定は `app.rb`、Web ヘルパは `helpers/`、ドメインロジックは `lib/`、ビューは `views/`、テストは `spec/`。

## 注意・制約

- ワンタイム URL を知る人は期限内・未使用なら登録できるため、共有先に注意する（仮押さえの決定・削除は実行したブラウザに限定される）。
- 反映先は Google の `primary` カレンダー。
- 本番は HTTPS 必須。OAuth リダイレクト URI は本番ドメインに合わせて登録する。
