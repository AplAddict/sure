class PortfolioHoldingsController < ApplicationController
  def show
    @portfolio = PortfolioHoldings.new(user: Current.user, account_id: params[:account], sort: params[:sort], direction: params[:dir])
    raise ActiveRecord::RecordNotFound unless @portfolio.scope_valid?

    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.portfolio_holdings"), nil ] ]
  end
end
