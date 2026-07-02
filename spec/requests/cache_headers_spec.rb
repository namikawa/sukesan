# frozen_string_literal: true

RSpec.describe "キャッシュ制御ヘッダ" do
  it "URL・登録内容・管理情報を扱う画面には Cache-Control: no-store を付ける" do
    %w[/admin /settings /sync /tickets /tickets?page=2 /t/anything].each do |path|
      get path
      expect(last_response.headers["Cache-Control"]).to eq("no-store"), "#{path} に no-store がない"
      expect(last_response.headers["Pragma"]).to eq("no-cache")
    end
  end

  it "公開トップには no-store を付けない" do
    get "/"
    expect(last_response.headers["Cache-Control"]).not_to eq("no-store")
  end

  it "静的アセット（/sync.js）には no-store を付けない" do
    get "/sync.js"
    expect(last_response.headers["Cache-Control"]).not_to eq("no-store")
  end
end
