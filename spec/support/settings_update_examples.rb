# frozen_string_literal: true

RSpec.shared_examples "設定の排他更新" do
  it "既定値と最新の全設定を渡し、更新結果を返す" do
    store.save("custom" => "retained")
    result = store.update do |current|
      expect(current).to include(defaults.merge("custom" => "retained"))
      [current.merge("business_start" => "11:00"), :updated]
    end
    expect(result).to eq(:updated)
    expect(store.load).to include(defaults.merge("custom" => "retained", "business_start" => "11:00"))
  end

  it "保存しない判定では既存ファイル・ドキュメントの更新も行わず、判定結果を返す" do
    store.save("custom" => "retained")
    revision = persisted_revision
    expect(store.update { |_current| [nil, :rejected] }).to eq(:rejected)
    expect(persisted_revision).to eq(revision)
    expect(store.load).to include("custom" => "retained")
  end

  it "save は部分保存を維持し、マージ済み全設定を返す" do
    store.save("custom" => "retained")
    expected = defaults.merge("custom" => "retained", "business_start" => "10:00")
    expect(store.save(business_start: "10:00")).to eq(expected)
    expect(store.load).to eq(expected)
  end
end
