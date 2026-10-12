class PortfolioHoldingsController < ApplicationController
  def show
    @portfolio = PortfolioHoldings.new(user: Current.user, account_id: params[:account], sort: params[:sort], direction: params[:dir])
    raise ActiveRecord::RecordNotFound unless @portfolio.scope_valid?

    @allocation = InvestmentAllocation.new(user: Current.user, by: params[:by])
    @sections = InvestmentSections.new(namespace: "holdings", user: Current.user, definitions: [
      { key: "allocation", title: t("portfolio_holdings.allocation_section"), partial: "portfolio_holdings/allocation_section", locals: { allocation: @allocation, currency: @allocation.currency } },
      { key: "data_quality", title: t("portfolio_holdings.data_quality_section"), partial: "portfolio_holdings/data_quality_section", locals: { issues: @allocation.data_quality } },
      { key: "accounts", title: t("portfolio_holdings.accounts_section"), flush: true, visible: @portfolio.blocks.any? }
    ])
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.portfolio_holdings"), nil ] ]
  end
end
