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

## 複数スケジュール仮押さえ

- 調整画面のタブから最大 5 件の日程を「[仮ブロック]」として仮押さえできる。仮押さえ後は同じ URL に 7 日間アクセスでき、1 件に決定すると残りは自動削除される（参加者・招待メール・会議 URL・Meet は決定時に指定）。
- 決定・削除と内容の閲覧は、仮押さえを行ったブラウザのみ可能。Cookie を失った場合は管理者が無効化して再発行する（無効化で残りの仮押さえイベントも削除される）。

## 設定（`/settings`）

- 営業時間・調整可能な曜日・昼休憩（時間帯と確保分数。0 分で無効）を設定する。時刻はすべて `APP_TIMEZONE`（既定 `Asia/Tokyo`）で解釈する。

## Outlook 同期

- Google・Outlook の両方を連携し、Outlook 側にのみある予定（突き合わせは「件名 + 開始 + 終了」）を選択して Google へ一方向で反映する。
- 取得範囲は日数（最大 180）か日付範囲で指定する。テストモードでは差分表示のみで反映しない。

## 他システム向け API

同一マシン上の別システムから、連携済み Google カレンダーの「特定の日のイベント一覧」を取得できる JSON API です。`/settings` で API キーを発行したときだけ有効になります（キーが 1 つもなければ `/api/` 配下は 404）。

- キーはシステム名を指定して発行する（64 文字・最大 20 件）。発行時に一度だけ表示され、サーバにはダイジェストのみ保存する。削除で即失効。
- 接続元は loopback に限定（`REMOTE_ADDR` 判定）。認証は `Authorization: Bearer <キー>` ヘッダのみ。レート制限はキーごとに 60 回/分。

エンドポイントは `GET /api/v1/calendars/google/events?date=YYYY-MM-DD`（`date` 省略時は当日）。

```bash
curl -H "Authorization: Bearer <キー>" \
  "http://127.0.0.1:3000/api/v1/calendars/google/events?date=2026-07-10"
```

レスポンスは `{"date": "...", "events": [...]}` で、各イベントは `id` / `title` / `starts_at` / `ends_at` / `location` / `all_day` を持つ。エラーは `{"error": {"code": "...", "message": "..."}}` 形式で、code は `invalid_date`（400）/ `unauthorized`（401）/ `forbidden`（403・loopback 以外）/ `not_found`（404）/ `rate_limited`（429）/ `upstream_error`（502）/ `provider_not_connected`（503・未連携）。

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
```

- ブラウザで <http://localhost:3000>（ポートは `PORT` で変更可）。
- ログは `log/` 配下で週次ローテーション。アクセスログはトークン・OAuth code をマスクし、監査ログは操作を 1 行 JSON で記録する。`LOG_TO_STDOUT=true` で stdout へ切替（コンテナ向け）。
- OS サービス登録用テンプレートは `deploy/`（systemd / launchd。`bin/server run` を起動コマンドにする）。
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
