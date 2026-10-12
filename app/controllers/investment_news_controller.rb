class InvestmentNewsController < ApplicationController
  def show
    @news = InvestmentNews.new(user: Current.user)
    @articles = @news.articles
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.investment_news"), nil ] ]
  end
end
