# SUKESAN

SUKESAN（スケジュール管理ツール）は、Google カレンダーと連携したスケジュール調整ツールです。管理者が発行する 1 回限り・24 時間有効のワンタイム URL から、依頼者が空き時間を選んで予定を登録できます。補助機能として、Outlook 側にのみある予定を Google へ反映する Outlook 同期（管理者専用）があります。

トップページ（`/`）は利用案内のみ。ワンタイム URL の発行・一覧・無効化は管理画面（`/admin`）、カレンダー連携や各種設定は設定画面（`/settings`）で行います。

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
- Microsoft トークンは `data/microsoft_token.json` に暗号化保存する（Outlook 同期専用。再起動後も保持）。

## 仕組み

- ワンタイム URL: 管理画面で発行（要 Google 連携）。発行から 24 時間有効・1 回登録で使用済み。一覧でステータス（有効 / 使用済み / 期限切れ / 無効化）と登録内容を確認でき、有効な URL はコピー・手動無効化が可能。無効な URL へのアクセスは HTTP 410 を返す。保存先は `data/tickets/`（ISO 週ごとに分割し、約 30 日で自動削除）。
- 調整フロー: 依頼者が期間と必要時間を入力 → 営業時間・曜日・昼休憩の設定に基づき 30 分刻みの空き候補を日付ごとに表示 → 枠と依頼者名・予定名を入力して登録。登録予定名は `[予定名] - [依頼者名] (from 調整ツール)`。検索だけでは URL は無効化されない。一度に表示するのは最大 5 営業日。
- 登録時の任意項目: 参加者メールアドレス（改行・カンマ・スペース区切りで複数可。イベントの参加者に登録するが招待メールは送らない）、ビデオ会議 URL（説明欄に記載）、Google Meet リンクの発行（発行時は完了画面にリンクを表示）。ビデオ会議 URL と Meet 発行は併用不可。主催者（連携した Google アカウント）も参加者として自動追加される。
- 設定（`/settings`）: 営業時間、調整可能な曜日、昼休憩（時間帯と確保分数。0 分で無効）を指定し、`data/settings.json` に永続化する。
- タイムゾーン: `APP_TIMEZONE`（既定 `Asia/Tokyo`）で固定し、画面にも表示する。
- アクセス制御・スパム対策: トークンの有効性と空き枠はサーバ側で再検証する（日付は ISO8601、所要時間は 15 分単位を要求し、UI 迂回の不正値を弾く）。二重登録を防ぐため登録前にトークンを消費し、失敗時のみ復帰させる。レート制限は同一 IP につき登録 5 回/分・空き時間検索 10 回/分（超過は 429。プロセス内メモリのため再起動でリセット、複数プロセスでは非共有）。
- 二重予約の抑止: 予約処理（空き再確認〜カレンダー登録）はロックで 1 件ずつ直列化し、別トークン同士が同じ枠をほぼ同時に予約しても後続をロック内の再確認で弾く。ロックは Mutex とロックファイルの flock を併用し、同一ホスト上の複数プロセスでも有効（NFS・複数ホストでは保証されない）。

## Outlook 同期（作成途中）

> ⚠️ この機能は開発途中で、動作の十分な確認が取れていません。本番利用は非推奨です。

Google・Outlook の両方を連携し、Outlook 側にのみある予定を抽出して、選択分を Google（`primary`）へ一方向で反映します。突き合わせは「件名 + 開始 + 終了」。

- 取得範囲は同期画面（`/sync`）で指定: 「日数で指定」（当日 0:00 起点〜N 日先、最大 180）か「日付範囲で指定」（開始日〜終了日、最大 180 日）をラジオで選ぶ。Google・Outlook 共通。日数は前回値を既定として記憶する。
- テストモード: チェック時に有効にすると、差分を一覧表示するだけで Google には反映しない（誤適用防止のためサーバ側でも反映を拒否）。通常モードは従来どおり差分を選択して反映する。
- 両カレンダーともページネーション（Google は `nextPageToken`、Outlook は `@odata.nextLink`）で全件取得する。

## セットアップ

依存 gem:

```bash
bundle install
```

OAuth クライアント:

- Google（必須）: Google Cloud Console で Calendar API を有効化し、OAuth クライアント ID（ウェブ）を作成。リダイレクト URI に `http://localhost:3000/auth/google/callback` を登録。スコープは `https://www.googleapis.com/auth/calendar.events`（予定の読み書き）と `https://www.googleapis.com/auth/userinfo.email`（主催者メールの取得）で、OAuth 同意画面にも両スコープを追加する。
- Microsoft（Outlook 同期を使う場合のみ）: Azure でアプリ登録し、リダイレクト URI `http://localhost:3000/auth/microsoft/callback` を登録。委任アクセス許可 `Calendars.Read` と `offline_access` を付与。

環境変数（`.env.example` をコピーして設定）:

```bash
cp .env.example .env
```

- `ADMIN_PASSWORD_DIGEST`: 管理者パスワードの bcrypt ダイジェスト（平文は保存しない）。`bin/admin_password_digest` で生成し、出力行を `.env` に貼り付ける。値に `$` を含むためシングルクォートで囲む。未設定だとログイン不可。
- `SESSION_SECRET`: セッション Cookie（署名付き）の鍵。64 文字以上が必須（短いと起動失敗）。本番（`APP_ENV=production`）は必須、開発は未設定なら一時生成。生成例 `ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'`。
- `TOKEN_ENCRYPTION_KEY`: 保存する OAuth トークン（Google / Microsoft）の暗号化鍵。本番は必須、開発は未設定なら `SESSION_SECRET` から導出。
- `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` と、Outlook 用の `MS_CLIENT_ID` / `MS_CLIENT_SECRET` / `MS_TENANT_ID`。
- `APP_TIMEZONE`: タイムゾーン（既定 `Asia/Tokyo`、tz database 名）。
- `APP_BASE_URL`: 公開 URL。OAuth の redirect_uri やチケット URL の生成に使い、Host ヘッダ汚染を排除する。本番（`APP_ENV=production`）では必須で、未設定だと起動に失敗する。開発は未設定ならリクエストから組み立てる。
- `.env` は `chmod 600` 推奨。

## 起動・運用

```bash
bin/server start     # 起動（バックグラウンド）
bin/server stop      # 停止
bin/server restart   # 再起動
bin/server status    # 状態確認
bin/server run       # フォアグラウンド（サービス管理用）
```

- 直接起動する場合は `bundle exec rackup -p 3000` または `ruby app.rb`。ブラウザで <http://localhost:3000>。
- PID は `tmp/pids/server.pid`。ログは `log/` 配下: アクセスログは `log/access.log`（週次ローテーション。過去週は `access.log.YYYYMMDD`）、プロセス出力（起動ログ・診断 `warn`）は `log/server.log`。ポートは `PORT` で変更可。
- OS サービス登録用テンプレートは `deploy/`（systemd: `sukesan.service` / launchd: `com.sukesan.server.plist`）。`bin/server run` を起動コマンドにし、`__APP_DIR__` 等を置換して登録する。
- `APP_ENV=production` で本番ハードニング（HTTPS 必須リダイレクト・Cookie の Secure 化・エラー秘匿・HSTS）が有効になる。HTTPS は前段プロキシで終端し `X-Forwarded-Proto` を渡す前提。

## データストア（file / firestore）

`STORE_BACKEND` で永続化の実装を切り替える（設定・OAuth トークン・チケット）。

- `file`（既定）: `data/` 配下のローカルファイル。flock で直列化するため単一ホスト前提（単一インスタンス＋永続ディスク）。開発や VM 運用向け。
- `firestore`: Google Cloud Firestore。read-modify-write はトランザクション／条件付き書き込みで処理するためロックファイル不要で、複数インスタンス・サーバレス（Cloud Run）でも一貫する。チケットの物理削除は `purge_at` フィールドの TTL ポリシーに委ねる。

どちらの実装でも、OAuth トークンとチケットの機微情報は `TOKEN_ENCRYPTION_KEY` で暗号化して保存する（Firestore では制御・クエリ用の最小限のフィールドのみ平文）。

## コンテナ / Cloud Run デプロイ

コンテナはプレーン HTTP で `$PORT`（Cloud Run は既定 8080）を listen し、TLS はプラットフォームが終端する前提（`nginx` 等は同梱しない）。

ローカルで本番相当（Firestore バックエンド）を動かす:

```bash
docker compose up --build   # アプリ + Firestore エミュレータ。http://localhost:3000
```

Cloud Run へのデプロイ手順（概略）:

1. Firestore（Native モード）を有効化し、`tickets` コレクションの `purge_at` フィールドに TTL ポリシーを設定する（期限切れチケットの自動削除）。`created_at_ts` は一覧の並べ替えに使う（単一フィールドインデックスで足りる）。
2. 秘密情報を Secret Manager に登録: `SESSION_SECRET`（64 文字以上）/ `TOKEN_ENCRYPTION_KEY` / `ADMIN_PASSWORD_DIGEST` / `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` /（Outlook 同期を使うなら）`MS_CLIENT_ID` / `MS_CLIENT_SECRET` / `MS_TENANT_ID`。`TOKEN_ENCRYPTION_KEY` はデプロイをまたいで固定し、別途バックアップする（変更・紛失で既存トークン・チケットが復号不能になる）。
3. ビルドしてデプロイ（Cloud Run は x86_64）:

   ```bash
   gcloud run deploy sukesan \
     --source . \
     --region asia-northeast1 \
     --allow-unauthenticated \
     --set-env-vars APP_ENV=production,STORE_BACKEND=firestore,APP_TRUST_PROXY=true,APP_BASE_URL=https://YOUR_DOMAIN,APP_TIMEZONE=Asia/Tokyo \
     --set-secrets SESSION_SECRET=SESSION_SECRET:latest,TOKEN_ENCRYPTION_KEY=TOKEN_ENCRYPTION_KEY:latest,ADMIN_PASSWORD_DIGEST=ADMIN_PASSWORD_DIGEST:latest,GOOGLE_CLIENT_ID=GOOGLE_CLIENT_ID:latest,GOOGLE_CLIENT_SECRET=GOOGLE_CLIENT_SECRET:latest
   ```

4. 独自ドメインはロードバランサを使わず Cloud Run のドメインマッピング（または Firebase Hosting）で割り当てる（管理 TLS・自動更新）。`APP_BASE_URL` と OAuth の redirect_uri を本番ドメインに合わせる。
5. `APP_TRUST_PROXY=true` で `X-Forwarded-Proto`（HTTPS 判定・リダイレクト）と `X-Forwarded-For`（レート制限の IP）を信頼する。

備考: Cloud Run はリクエストログを自動収集するため、アプリ側のアクセスログ（`log/access.log`）は基本的に不要（コンテナの揮発 FS に出力される）。レート制限はインスタンス内メモリのため、複数インスタンス間では共有されない。

## 開発

```bash
bundle exec rspec          # テスト
bundle exec rubocop        # Lint（-a で自動修正）
```

構成: ルートと起動設定は `app.rb`、Web ヘルパは `helpers/`、ドメインロジックは `lib/`（空き時間検索は `lib/availability_search.rb`、チケットは `lib/ticket_store.rb` など）、ビューは `views/`、テストは `spec/`。

## データと機微情報

`data/` 配下のファイルは本人のみ読み書き可（0600）・Atomic に書き込む。OAuth トークンとチケットは加えて暗号化保存する（設定ファイルは権限のみ）。

- `data/settings.json`: 調整時間などの設定。
- `data/google_token.json`: Google OAuth トークン（refresh token を含む）。
- `data/microsoft_token.json`: Microsoft OAuth トークン（Outlook 同期用、refresh token を含む）。
- `data/tickets/`: 発行済みワンタイム URL の状態と登録内容。

## 注意・制約

- OAuth トークン（Google / Microsoft）とチケットはファイルに暗号化保存され、再起動後も保持される。
- ワンタイム URL を知る人は期限内・未使用なら登録できるため、共有先に注意する。
- 反映先は Google の `primary` カレンダー。
- 本番は HTTPS 必須。OAuth リダイレクト URI は本番ドメインに合わせて登録する。
