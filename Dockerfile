# syntax=docker/dockerfile:1
# SUKESAN 本番イメージ。Cloud Run など前段で TLS 終端する環境を前提とする
# （コンテナはプレーン HTTP で $PORT を listen する。TLS はプラットフォームが終端）。
FROM ruby:3.4.9-slim

# bcrypt のネイティブ拡張ビルドに必要（grpc 等は precompiled gem を利用）。
RUN apt-get update -qq \
  && apt-get install -y --no-install-recommends build-essential \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 本番依存のみインストール（development/test は除外）。
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test
COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf /usr/local/bundle/cache

COPY . .

# 非 root で実行し、書き込みが要るディレクトリ（log/・データの一時書き込み）を所有させる。
# 本番は STORE_BACKEND=firestore 想定だが、file バックエンドでも data/ を書けるようにしておく。
RUN useradd --create-home --shell /usr/sbin/nologin app \
  && mkdir -p log data \
  && chown -R app:app /app
USER app

# Cloud Run は PORT（既定 8080）を注入する。アプリは ENV["PORT"] を見て 0.0.0.0:$PORT で listen する。
ENV PORT=8080 \
    APP_ENV=production
EXPOSE 8080

CMD ["bundle", "exec", "ruby", "app.rb"]
