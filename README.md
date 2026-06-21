# SUKESAN

SUKESAN（スケジュール管理ツール）は、Google カレンダーと連携したスケジュール調整ツールです。管理者が発行する 1 回限り・24 時間有効のワンタイム URL から、依頼者が空き時間を選んで予定を登録できます。補助機能として、Outlook 側にのみある予定を Google へ反映する Outlook 同期（管理者専用）があります。

トップページ（`/`）は利用案内のみ。ワンタイム URL の発行・一覧・無効化は管理画面（`/admin`）、カレンダー連携や各種設定は設定画面（`/settings`）で行います。管理系はパスワードで保護され、動線はトップ → 管理画面 → 設定画面です。

## 画面と権限

| URL | 権限 | 内容 |
| --- | --- | --- |
| `GET /` | 公開 | 利用案内ページ |
| `GET /t/:token` | トークン | 調整ページ（空き候補の検索・登録） |
| `POST /schedule` | トークン | 空き枠を登録し、トークンを使用済みにする |
| `GET /admin` | 管理者 | ワンタイム URL の発行・一覧・無効化（未ログイン時はログイン画面） |
| `POST /tickets` / `POST /tickets/:token/revoke` | 管理者 | URL の発行 / 無効化 |
| `GET /settings` / `POST /settings` | 管理者 | カレンダー連携・調整時間などの設定 |
| `GET /sync` ほか | 管理者 | Outlook → Google 同期 |
| `/auth/google`, `/auth/microsoft` | 管理者 | OAuth 連携 |

権限の意味:

- 公開 = 認証不要。
- トークン = 有効なワンタイム URL が必要（管理者ログインは不要）。
- 管理者 = `ADMIN_PASSWORD_DIGEST` でのログインが必要。未認証で管理ページにアクセスすると `/admin` のログインへ誘導される。

トークンの保存場所:

- Google トークンは `data/google_token.json` に共有保存し、全利用者が管理者の 1 カレンダー（`primary`）を参照する。
- Microsoft トークンは管理者セッションのみに保持する（Outlook 同期専用）。

## 仕組み

- ワンタイム URL: 管理画面で発行（要 Google 連携）。発行から 24 時間有効・1 回登録で使用済み。一覧でステータス（有効 / 使用済み / 期限切れ / 無効化）と登録内容を確認でき、有効な URL はコピー・手動無効化が可能。無効な URL へのアクセスは HTTP 410 を返す。保存先は `data/tickets/`（ISO 週ごとに分割し、約 30 日で自動削除）。
- 調整フロー: 依頼者が期間と必要時間を入力 → 営業時間・曜日・昼休憩の設定に基づき 30 分刻みの空き候補を日付ごとに表示 → 枠と依頼者名・予定名を入力して登録。登録予定名は `[予定名] - [依頼者名] (from 調整ツール)`。検索だけでは URL は無効化されない。一度に表示するのは最大 5 営業日。
- 設定（`/settings`）: 営業時間、調整可能な曜日、昼休憩（時間帯と確保分数。0 分で無効）を指定し、`data/settings.json` に永続化する。
- タイムゾーン: `APP_TIMEZONE`（既定 `Asia/Tokyo`）で固定し、画面にも表示する。
- アクセス制御・スパム対策: トークンの有効性と空き枠はサーバ側で再検証する。二重登録を防ぐため登録前にトークンを消費し、失敗時のみ復帰させる。レート制限は同一 IP につき登録 5 回/分・空き時間検索 10 回/分（超過は 429。プロセス内メモリのため再起動でリセット、複数プロセスでは非共有）。

## Outlook 同期（作成途中）

> ⚠️ この機能は作成途中で、動作の十分な確認が取れていません。本番利用は非推奨です。

Google・Outlook の両方を連携し、Outlook 側にのみある予定を抽出して、選択分を Google（`primary`）へ一方向で反映します。突き合わせは「件名 + 開始 + 終了」。対象期間は 1 日前〜60 日後（`app.rb` の `SYNC_WINDOW_PAST` / `SYNC_WINDOW_FUTURE`）。

## セットアップ

依存 gem:

```bash
bundle install
```

OAuth クライアント:

- Google（必須）: Google Cloud Console で Calendar API を有効化し、OAuth クライアント ID（ウェブ）を作成。リダイレクト URI に `http://localhost:3000/auth/google/callback` を登録。スコープは `https://www.googleapis.com/auth/calendar.events`。
- Microsoft（Outlook 同期を使う場合のみ）: Azure でアプリ登録し、リダイレクト URI `http://localhost:3000/auth/microsoft/callback` を登録。委任アクセス許可 `Calendars.Read` と `offline_access` を付与。

環境変数（`.env.example` をコピーして設定）:

```bash
cp .env.example .env
```

- `ADMIN_PASSWORD_DIGEST`: 管理者パスワードの bcrypt ダイジェスト（平文は保存しない）。`bin/admin_password_digest` で生成し、出力行を `.env` に貼り付ける。値に `$` を含むためシングルクォートで囲む。未設定だとログイン不可。
- `SESSION_SECRET`: セッション Cookie の署名鍵。本番（`APP_ENV=production`）は必須、開発は未設定なら一時生成。生成例 `ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'`。
- `TOKEN_ENCRYPTION_KEY`: 保存する Google トークンの暗号化鍵。本番は必須、開発は未設定なら `SESSION_SECRET` から導出。
- `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` と、Outlook 用の `MS_CLIENT_ID` / `MS_CLIENT_SECRET` / `MS_TENANT_ID`。
- `APP_TIMEZONE`: タイムゾーン（既定 `Asia/Tokyo`、tz database 名）。
- `APP_BASE_URL`: 公開 URL（本番推奨）。OAuth の redirect_uri 等の生成に使い、Host ヘッダ汚染を排除する。未設定時はリクエストから組み立てる。
- `.env` は `chmod 600` 推奨。コミット禁止。

## 起動・運用

```bash
bin/server start     # 起動（バックグラウンド）
bin/server stop      # 停止
bin/server restart   # 再起動
bin/server status    # 状態確認
bin/server run       # フォアグラウンド（サービス管理用）
```

- 直接起動する場合は `bundle exec rackup -p 3000` または `ruby app.rb`。ブラウザで <http://localhost:3000>。
- PID は `tmp/pids/server.pid`、ログは `log/server.log`。ポートは `PORT` で変更可。
- OS サービス登録用テンプレートは `deploy/`（systemd: `sukesan.service` / launchd: `com.sukesan.server.plist`）。`bin/server run` を起動コマンドにし、`__APP_DIR__` 等を置換して登録する。
- `APP_ENV=production` で本番ハードニング（HTTPS 必須リダイレクト・Cookie の Secure 化・エラー秘匿・HSTS）が有効になる。HTTPS は前段プロキシで終端し `X-Forwarded-Proto` を渡す前提。

## 開発

```bash
bundle exec rspec          # テスト
bundle exec rubocop        # Lint（-a で自動修正）
```

構成: ルートと起動設定は `app.rb`、Web ヘルパは `helpers/`、ドメインロジックは `lib/`（空き時間検索は `lib/availability_search.rb`、チケットは `lib/ticket_store.rb` など）、ビューは `views/`、テストは `spec/`。

## データと機微情報

- `data/settings.json`: 調整時間などの設定。
- `data/google_token.json`: Google OAuth トークン（refresh token を含む）。
- `data/tickets/`: 発行済みワンタイム URL の状態と登録内容。

## 注意・制約

- Microsoft トークンと管理者ログイン状態はメモリ保持で、再起動すると失われる（Google トークンとチケットはファイル保存）。
- ワンタイム URL を知る人は期限内・未使用なら登録できるため、共有先に注意する。
- 反映先は Google の `primary` カレンダー。
- 本番は HTTPS 必須。OAuth リダイレクト URI は本番ドメインに合わせて登録する。
