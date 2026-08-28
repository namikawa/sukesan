# frozen_string_literal: true

# 一覧のページング。管理画面（GET /tickets）と API（GET /api/v1/tickets）で同じ流儀を保つため、
# 件数・ページ番号の解釈を 1 か所にまとめる。PER_PAGE_OPTIONS / DEFAULT_PER_PAGE は app.rb の定数を
# 参照する（ビュー（views/tickets.erb）が選択肢の描画に直接使うため、モジュールへは移さない）。
module PaginationHelpers
  # 切り出したページと、表示に必要な件数情報。
  Page = Struct.new(:items, :page, :per, :total, :total_pages, keyword_init: true)

  # items をリクエストの per / page パラメータで切り出す。
  # ページは 1 以上に丸め、範囲外は端へクランプする（総ページ数は最低 1）。
  def paginate(items)
    per = requested_per_page
    total_pages = [(items.size.to_f / per).ceil, 1].max
    page = params[:page].to_i.clamp(1, total_pages)
    Page.new(items: items.slice((page - 1) * per, per) || [], page: page, per: per,
             total: items.size, total_pages: total_pages)
  end

  # 表示件数はホワイトリスト照合（不正値・未指定は既定 10）。
  def requested_per_page
    PER_PAGE_OPTIONS.include?(params[:per].to_i) ? params[:per].to_i : DEFAULT_PER_PAGE
  end
end
