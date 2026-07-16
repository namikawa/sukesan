# frozen_string_literal: true

source "https://rubygems.org"

ruby "3.4.10"

gem "bcrypt"     # 管理者パスワードのハッシュ化（ダイジェスト照合）
gem "dotenv"     # .env からの環境変数読み込み
gem "erubi"      # ERB テンプレートの HTML 自動エスケープ（XSS 対策）
gem "google-cloud-firestore" # 本番データストア（STORE_BACKEND=firestore）
gem "holiday_jp" # 日本の祝日判定（内閣府データ由来・gem 同梱でネットワーク不要）。空き候補から祝日を除外
gem "oauth2"     # Google / Microsoft の OAuth2 認可フローとトークン管理
gem "puma"       # アプリケーションサーバ
gem "rackup"     # Sinatra クラシック起動（run!）のサーバハンドラ（Rackup::Handler）に必須
gem "sinatra"    # Web フレームワーク

group :development, :test do
  gem "bundler-audit" # 依存 gem の既知脆弱性チェック（CI で実行。Gemfile.lock でバージョン固定）
  gem "rack-test"  # リクエストスペック（Sinatra アプリを直接叩く）
  gem "rspec"
  gem "rubocop"
  gem "webmock"    # 外部 API 呼び出しのスタブ
end
