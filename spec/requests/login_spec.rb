# frozen_string_literal: true

RSpec.describe "管理者ログイン" do
  it "CSRF トークンが無いと 403" do
    post "/settings/login", password: ENV.fetch("ADMIN_PASSWORD")
    expect(last_response.status).to eq(403)
  end

  it "誤ったパスワードでは管理者にならない" do
    post "/settings/login", authenticity_token: csrf_token, password: "wrong"
    get "/settings"
    expect(last_response.body).to include("管理者ログイン")
  end

  it "正しいパスワードで管理者になる" do
    login_admin!
    get "/settings"
    expect(last_response.body).to include("スケジュール設定")
  end

  it "失敗が規定回数を超えると 429 を返す" do
    token = csrf_token
    statuses = Array.new(12) do
      post "/settings/login", authenticity_token: token, password: "wrong"
      last_response.status
    end
    expect(statuses).to include(429)
  end

  it "成功ログインはレート制限を消費しない（連続成功でも 429 にならない）" do
    statuses = Array.new(12) do
      login_admin!
      last_response.status
    end
    expect(statuses).not_to include(429)
  end

  describe "ログイン後の戻り先（return_to）" do
    it "ログイン画面に描画時のパスが return_to として埋め込まれ、成功時にそのページへ戻る" do
      get "/tickets"
      expect(last_response.body).to include("管理者ログイン") # 未認証なのでログイン画面
      expect(last_response.body).to include('name="return_to" value="/tickets"')

      token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
      post "/settings/login", authenticity_token: token,
                              password: ENV.fetch("ADMIN_PASSWORD"), return_to: "/tickets"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["Location"]).to end_with("/tickets")
    end

    it "許可リスト外の return_to は /admin にフォールバックする（open redirect 防止）" do
      ["https://evil.example", "//evil.example", "/t/xxx", "/admin?x=1", ""].each do |value|
        post "/settings/login", authenticity_token: csrf_token,
                                password: ENV.fetch("ADMIN_PASSWORD"), return_to: value
        expect(last_response.status).to eq(302)
        location = URI(last_response.headers["Location"])
        expect(location.host).to eq("example.org"), "return_to=#{value.inspect} で外部へ飛んだ"
        expect(location.path).to eq("/admin")
      end
    end

    it "return_to が無いときは /admin へリダイレクトする" do
      login_admin!
      expect(last_response.status).to eq(302)
      expect(last_response.headers["Location"]).to end_with("/admin")
    end

    it "ログイン失敗時は検証済みの戻り先へリダイレクトする（再びログイン画面が出る）" do
      post "/settings/login", authenticity_token: csrf_token, password: "wrong", return_to: "/sync"
      expect(last_response.status).to eq(302)
      expect(last_response.headers["Location"]).to end_with("/sync")

      follow_redirect!
      expect(last_response.body).to include("管理者ログイン") # 未認証のままログイン画面
      expect(last_response.body).to include("パスワードが正しくありません。") # flash も維持
      expect(last_response.body).to include('name="return_to" value="/sync"') # 戻り先も維持
    end
  end

  it "ログインから TTL（24 時間）を超えたセッションは管理者扱いしない" do
    login_admin!
    get "/sync"
    expect(last_response.body).not_to include("管理者ログイン") # ログイン直後は管理者

    future = Time.now + AuthHelpers::ADMIN_SESSION_TTL + 60
    allow(Time).to receive(:now).and_return(future)
    get "/sync"
    expect(last_response.status).to eq(200)
    expect(last_response.body).to include("管理者ログイン") # 管理者扱いされずログイン画面に戻る
  end
end
