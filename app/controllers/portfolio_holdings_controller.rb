class PortfolioHoldingsController < ApplicationController
  def show
    @portfolio = PortfolioHoldings.new(user: Current.user, account_id: params[:account], sort: params[:sort], direction: params[:dir])
    raise ActiveRecord::RecordNotFound unless @portfolio.scope_valid?

    @allocation = InvestmentAllocation.new(user: Current.user, by: params[:by])
    @options_now = Time.current
    @account_options = account_options_for(@portfolio, @options_now)
    @sections = InvestmentSections.new(namespace: "holdings", user: Current.user, definitions: [
      { key: "allocation", title: t("portfolio_holdings.allocation_section"), partial: "portfolio_holdings/allocation_section", locals: { allocation: @allocation, currency: @allocation.currency } },
      { key: "data_quality", title: t("portfolio_holdings.data_quality_section"), partial: "portfolio_holdings/data_quality_section", locals: { issues: @allocation.data_quality } },
      { key: "accounts", title: t("portfolio_holdings.accounts_section"), flush: true, visible: @portfolio.blocks.any?,
        partial: "portfolio_holdings/accounts_section", locals: { portfolio: @portfolio, account_id: params[:account].presence, account_options: @account_options, now: @options_now } }
    ])
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.portfolio_holdings"), nil ] ]
  end

  private
    # One approved OptionsDesk read per broker-linked account, scoped to that account only. Accounts without a broker
    # link have no option data to show, so they get no entry (and therefore no broker notice).
    def account_options_for(portfolio, now)
      linked = portfolio.snaptrade_account_ids.to_set
      portfolio.blocks.filter_map do |block|
        next unless linked.include?(block.account.id)

        [ block.account.id, OptionsDesk.new(user: Current.user, account_id: block.account.id, now: now).result ]
      end.to_h
    end
end
