# 変更履歴

## [1.0.0] - 2026-09-28

初回リリース。

### スケジュール登録（ワンタイム URL）

- 管理者が発行するワンタイム URL から、依頼者が空き時間を選んで Google カレンダーへ予定を登録する。
  URL は 1 回の登録で使用済みになり、有効期限は発行時に 24 時間・72 時間・7 日から選ぶ。
- 空き候補は営業時間・曜日・昼休憩の設定と日本の祝日に基づいて 30 分刻みで算出する。枠と入力値は
  サーバ側で再検証し、同一枠の二重予約は登録の直列化と空きの再確認で防ぐ。
- 参加者・ビデオ会議 URL・Google Meet を任意で指定できる。招待メールの送付と予定の非公開は
  依頼者がチェックしたときだけ行う。
- 予約・仮押さえ・決定・全取りやめを管理者の Slack に通知できる（メンションの指定可）。

### 仮押さえ

- 最大 5 件の日程を `[仮ブロック]` として仮押さえし、7 日以内に 1 件へ決定する（残りは自動で削除）。
- 決定・削除と内容の閲覧は、仮押さえを行ったブラウザだけができる。

### 管理画面

- 管理者は bcrypt ダイジェストで照合するパスワードでログインする。失敗回数でレート制限し、
  セッションは 24 時間で失効する。
- ワンタイム URL の発行・一覧・無効化（`/tickets`）、カレンダー連携・調整時間・API キーの設定
  （`/settings`）。
- Outlook 側にのみある予定を選んで Google へ一方向で反映する Outlook 同期（`/sync`）。取得範囲は
  最大 180 日で、差分の表示だけを行うテストモードがある。
- `bin/check_admin_password` で、ログインできない原因が入力とダイジェストのどちらにあるかを診断できる。

### 他システム向け API（/api/v1）

- 同一マシン上の別システム向けの JSON API（12 エンドポイント）。イベント一覧・空き候補の検索・
  予定の登録と取消・仮押さえ・ワンタイム URL の発行と無効化ができる。
- `/settings` で API キー（`read` / `write`）を発行したときだけ有効になり、接続元は loopback に限る。
  書き込み系は `Idempotency-Key` で再送時の二重登録を防ぐ。仕様は [docs/api.md](docs/api.md)。

### セキュリティ

- CSP・CSRF トークン・`Cache-Control: no-store`・暗号化 Cookie のセッション。
- OAuth トークンとチケットは AES-256-GCM で暗号化して保存する。
- `APP_ENV=production` で HTTPS へのリダイレクト・Secure Cookie・HSTS を有効にし、必須の設定が
  無ければ起動しない。
- 状態を変える操作を監査ログ（1 行 JSON）に記録し、アクセスログのトークン・OAuth code はマスクする。

### 運用

- `bin/server` で起動・停止・再起動・状態確認を行う。macOS は `bin/server install` で launchd に
  常駐させる（Linux 向けに systemd のテンプレートを同梱）。
- アクセス・監査・サーバのログは週次でローテーションする。`LOG_TO_STDOUT=true` でアクセス・監査ログを
  stdout へ出す。
- データストアは `file`（既定・ローカルファイル）と `firestore`（Cloud Run 向け）を `STORE_BACKEND`
  で切り替える。Cloud Run 向けの Dockerfile を同梱。

### 動作環境

- Ruby 3.4.10、Bundler
- Google カレンダー（必須）。Outlook 同期を使う場合は Microsoft のアプリ登録
- macOS（launchd）/ Linux（systemd）/ Cloud Run（`max-instances 1`）

[1.0.0]: https://github.com/namikawa/sukesan/releases/tag/v1.0.0
