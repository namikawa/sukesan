# Cloud Run デプロイ手順

sukesan を Google Cloud Run（+ Firestore）へデプロイするための手順。
本番前のお試しデプロイ（既定の `*.run.app` URL を使う構成）を想定する。

前提となる設計方針は `CLAUDE.md` の「Cloud Run デプロイ」「データストアのバックエンド」を参照。
要点は次の 3 つ。

- `STORE_BACKEND=firestore`（複数インスタンス・サーバレス向け）
- `--max-instances 1`（slot の二重予約防止が `BOOKING_LOCK`＝プロセス内 Mutex 依存のため）
- 秘密は Secret Manager、`APP_BASE_URL` は ENV 固定（Host ヘッダから組み立てない）

## 0. 変数の準備

以下では例として次の値を使う。自分の環境に合わせて置き換える。

```bash
export PROJECT_ID=sukesan-trial      # 任意の GCP プロジェクト ID
export REGION=asia-northeast1         # 東京リージョン
export SERVICE=sukesan                # Cloud Run サービス名
```

前提ツール:

- `gcloud` CLI（インストール済み・課金有効なプロジェクト）
- ログイン: `gcloud auth login`

## 1. プロジェクト設定と API 有効化

```bash
gcloud config set project $PROJECT_ID
gcloud services enable \
  run.googleapis.com \
  firestore.googleapis.com \
  secretmanager.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com
```

## 2. Firestore（Native モード）を作成

```bash
gcloud firestore databases create --location=$REGION
```

## 3. シークレット生成と Secret Manager 登録

本番（`APP_ENV=production`）で必須・未設定なら起動失敗するのは
`SESSION_SECRET` / `TOKEN_ENCRYPTION_KEY` / `APP_BASE_URL` の 3 つ。
このうち 2 つの鍵と、管理者パスワードダイジェスト、OAuth クライアント秘密を Secret Manager に置く。

ローカルで生成:

```bash
# セッション署名鍵・トークン暗号化鍵（各 64 文字以上）
ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'   # → SESSION_SECRET 用
ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'   # → TOKEN_ENCRYPTION_KEY 用

# 管理者パスワードの bcrypt ダイジェスト（対話で入力）
bundle exec bin/admin_password_digest
```

Secret Manager に登録（値はパイプで渡し、シェル履歴に平文を残さない）:

```bash
printf '%s' '生成した SESSION_SECRET'      | gcloud secrets create SESSION_SECRET --data-file=-
printf '%s' '生成した TOKEN_ENCRYPTION_KEY' | gcloud secrets create TOKEN_ENCRYPTION_KEY --data-file=-
printf '%s' '$2a$12$....(digest)'          | gcloud secrets create ADMIN_PASSWORD_DIGEST --data-file=-

# OAuth クライアント秘密（手順 5 で取得した値）
printf '%s' 'google-client-secret' | gcloud secrets create GOOGLE_CLIENT_SECRET --data-file=-
printf '%s' 'ms-client-secret'     | gcloud secrets create MS_CLIENT_SECRET --data-file=-
```

注意: `TOKEN_ENCRYPTION_KEY` は変更・紛失すると既存トークン・チケットが復号不能になる。固定保持する。

## 4. 初回デプロイ（URL を取得するブートストラップ）

本番モードは `APP_BASE_URL` 必須だが、その値（`*.run.app`）はデプロイするまで分からない。
初回だけ `APP_ENV=development` で上書き起動し、払い出される URL を確定させる。

```bash
gcloud run deploy $SERVICE \
  --source . \
  --region $REGION \
  --max-instances 1 \
  --allow-unauthenticated \
  --set-env-vars APP_ENV=development,STORE_BACKEND=firestore,APP_TRUST_PROXY=true,GOOGLE_CLOUD_PROJECT=$PROJECT_ID

export APP_URL=$(gcloud run services describe $SERVICE --region $REGION --format='value(status.url)')
echo $APP_URL
```

`--source .` で Cloud Build が Dockerfile からビルドし、Artifact Registry に push してデプロイまで自動で行う。

`GOOGLE_CLOUD_PROJECT` は Firestore のプロジェクト ID 解決（`lib/stores/firestore_client.rb`）に必須。Cloud Run は自動設定しないため、未指定だと起動時に `FIRESTORE_PROJECT_ID / GOOGLE_CLOUD_PROJECT が未設定です` で失敗する。

注意: このブートストラップは URL の払い出しだけが目的。`APP_ENV=development` では Sinatra 4 の `host_authorization` が `*.run.app` を許可せず（dev の許可は localhost/.localhost/.test/IP のみ）、ブラウザで開くと `403 Host not permitted` になる。URL は上記 `describe` で取得すれば十分で、画面の疎通確認は本番モード（手順6）後に行う（本番は `host_authorization` が全ホスト許可になる）。

独自ドメインを先に決められる場合は、このブートストラップは不要。
`APP_BASE_URL` を確定済みドメインにして、手順 6 を 1 回実行すればよい。

## 5. OAuth リダイレクト URI を登録

確定した `$APP_URL` を使って各コンソールにコールバックを登録する。
コールバックのパスはアプリ側で固定（`helpers/oauth_helpers.rb`）。

- Google Cloud Console → 認証情報 → OAuth クライアント
  - 承認済みリダイレクト URI: `${APP_URL}/auth/google/callback`
  - スコープは最小（`calendar.events` ＋ `userinfo.email`）
- Azure Portal → アプリ登録 → 認証
  - リダイレクト URI: `${APP_URL}/auth/microsoft/callback`
  - API のアクセス許可: `Calendars.Read` ＋ `offline_access`

クライアント ID（`GOOGLE_CLIENT_ID` / `MS_CLIENT_ID`）は公開値なので手順 6 の `--set-env-vars` で渡す。
クライアント秘密 2 つは手順 3 で Secret Manager に登録済み。

## 6. 本番設定で再デプロイ

ランタイムのサービスアカウントに Firestore とシークレットへのアクセス権を付与する。

```bash
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
RUNTIME_SA=${PROJECT_NUMBER}-compute@developer.gserviceaccount.com

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${RUNTIME_SA}" --role="roles/datastore.user" --condition=None

for S in SESSION_SECRET TOKEN_ENCRYPTION_KEY ADMIN_PASSWORD_DIGEST GOOGLE_CLIENT_SECRET MS_CLIENT_SECRET; do
  gcloud secrets add-iam-policy-binding $S \
    --member="serviceAccount:${RUNTIME_SA}" --role="roles/secretmanager.secretAccessor"
done
```

本番モードで再デプロイ（`APP_ENV=production` ＋ `APP_BASE_URL`、secret 注入）:

```bash
gcloud run deploy $SERVICE \
  --source . \
  --region $REGION \
  --max-instances 1 \
  --allow-unauthenticated \
  --set-env-vars APP_ENV=production,STORE_BACKEND=firestore,APP_TRUST_PROXY=true,GOOGLE_CLOUD_PROJECT=$PROJECT_ID,APP_BASE_URL=${APP_URL},APP_TIMEZONE=Asia/Tokyo,GOOGLE_CLIENT_ID=xxxx,MS_CLIENT_ID=xxxx,MS_TENANT_ID=common \
  --set-secrets SESSION_SECRET=SESSION_SECRET:latest,TOKEN_ENCRYPTION_KEY=TOKEN_ENCRYPTION_KEY:latest,ADMIN_PASSWORD_DIGEST=ADMIN_PASSWORD_DIGEST:latest,GOOGLE_CLIENT_SECRET=GOOGLE_CLIENT_SECRET:latest,MS_CLIENT_SECRET=MS_CLIENT_SECRET:latest
```

## 7. Firestore の TTL ポリシー

firestore バックエンドは物理削除を `purge_at` の TTL に委譲する（`prune!` は no-op）。

```bash
gcloud firestore fields ttls update purge_at \
  --collection-group=tickets --enable-ttl
```

## 8. 動作確認

```bash
curl -I $APP_URL                                        # 200 または適切なリダイレクト＋ no-store ヘッダ
gcloud run services logs read $SERVICE --region $REGION --limit 50
```

ブラウザで `$APP_URL` を開き、`/settings` で管理者ログイン → Google / Microsoft 連携 →
チケット発行 → 予約までの一連を確認する。

## 独自ドメインに載せる場合（将来）

- LB ではなくドメインマッピングを使う（`CLAUDE.md` 参照）。
- `APP_BASE_URL` をそのドメインに変えて手順 6 を再実行。
- OAuth リダイレクト URI も新ドメインのものに更新する。
