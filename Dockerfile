# syntax=docker/dockerfile:1
# SUKESAN 本番イメージ。Cloud Run など前段で TLS 終端する環境を前提とする
# （コンテナはプレーン HTTP で $PORT を listen する。TLS はプラットフォームが終端）。

# ---- builder: ネイティブ拡張（bcrypt 等）のビルドだけを行う ----
FROM ruby:4.0.5-slim AS builder

# bcrypt のネイティブ拡張ビルドに必要（grpc 等は precompiled gem を利用）。
RUN apt-get update -qq \
  && apt-get install -y --no-install-recommends build-essential \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 本番依存のみインストール（development/test は除外）。インストール先を /usr/local/bundle に固定し、
# runtime へはそのディレクトリだけ持ち込めばよいようにする。
ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle
COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf /usr/local/bundle/cache

# ---- runtime: compiler toolchain を含まない最終イメージ ----
FROM ruby:4.0.5-slim

WORKDIR /app

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=development:test \
    BUNDLE_PATH=/usr/local/bundle

# builder で導入した gem（コンパイル済み拡張を含む）をそのまま持ち込む。builder/runtime は
# 同じベースイメージ（同 OS/arch）なので、拡張モジュールはそのまま動く。
COPY --from=builder /usr/local/bundle /usr/local/bundle
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
