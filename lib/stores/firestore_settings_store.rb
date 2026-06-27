# frozen_string_literal: true

require "google/cloud/firestore"

# 設定の Firestore 永続化アダプタ（STORE_BACKEND=firestore）。
#
# 単一ドキュメント（既定 settings/app）に設定値を平文フィールドで保存する（設定は非機密のため暗号化しない。
# ファイル実装と方針を揃える）。save はトランザクションで read-merge-write し、複数画面からの同時保存で
# 一部設定が巻き戻るのを防ぐ（flock は不要）。既定値（defaults）は呼び出し側から注入する。
class FirestoreSettingsStore
  def initialize(defaults:, firestore:, document: "settings/app")
    @defaults = defaults
    @firestore = firestore
    @doc = firestore.doc(document)
  end

  def load
    snapshot = @doc.get
    return @defaults.dup unless snapshot.exists?

    @defaults.merge(stringify(snapshot.data))
  end

  # 指定した項目だけを既存設定にマージして保存する（未指定の項目は保持する）。
  def save(attrs)
    merged = nil
    @firestore.transaction do |tx|
      snapshot = tx.get(@doc)
      current = snapshot.exists? ? stringify(snapshot.data) : {}
      merged = @defaults.merge(current).merge(attrs.transform_keys(&:to_s))
      tx.set(@doc, merged)
    end
    merged
  end

  private

  # Firestore はキーをシンボルで返すため、アプリ内表現（文字列キー）へ揃える。
  def stringify(data)
    data.transform_keys(&:to_s)
  end
end
