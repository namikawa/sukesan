# frozen_string_literal: true

require "google/cloud/firestore"

# Firestore クライアントの生成を一元化する。全ストアで 1 つのクライアント（gRPC チャネル）を共有する。
# エミュレータ利用時（FIRESTORE_EMULATOR_HOST）は認証不要・project_id はダミーで可。
# 本番は GOOGLE_CLOUD_PROJECT などからプロジェクト ID を解決する（未設定なら起動失敗）。
module FirestoreClient
  module_function

  def build
    @build ||= Google::Cloud::Firestore.new(project_id: project_id)
  end

  def project_id
    ENV["FIRESTORE_PROJECT_ID"] || ENV["GOOGLE_CLOUD_PROJECT"] || ENV["GCLOUD_PROJECT"] ||
      (ENV["FIRESTORE_EMULATOR_HOST"] ? "sukesan-local" : raise("FIRESTORE_PROJECT_ID / GOOGLE_CLOUD_PROJECT が未設定です"))
  end
end
