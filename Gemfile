# frozen_string_literal: true

source "https://rubygems.org"

ruby "3.4.9"

gem "bcrypt"     # 管理者パスワードのハッシュ化（ダイジェスト照合）
gem "dotenv"     # .env からの環境変数読み込み
gem "erubi"      # ERB テンプレートの HTML 自動エスケープ（XSS 対策）
gem "google-cloud-firestore" # 本番データストア（STORE_BACKEND=firestore）
gem "oauth2"     # Google / Microsoft の OAuth2 認可フローとトークン管理
gem "puma"       # アプリケーションサーバ
gem "rackup"     # config.ru 起動用
gem "sinatra"    # Web フレームワーク

group :development, :test do
  gem "rack-test"  # リクエストスペック（Sinatra アプリを直接叩く）
  gem "rspec"
  gem "rubocop"
  gem "webmock"    # 外部 API 呼び出しのスタブ
end
