require "test_helper"

class DashboardPageTemplateRegistryTest < ActiveSupport::TestCase
  EXPECTED = {
    "daily_investment_check" => %w[portfolio.pulse review.needs_review review.source_health options.expiring tax.harvest_candidates research.upcoming_events research.portfolio_news],
    "portfolio_review" => %w[portfolio.holdings_concentration portfolio.allocation portfolio.top_holdings review.data_quality income.summary research.portfolio_news],
    "income_risk" => %w[income.summary income.monthly income.cash_flows income.return_risk tax.realized_gains income.options_premium],
    "tax_review" => %w[tax.lot_coverage tax.nearing_long_term tax.harvest_summary tax.harvest_candidates tax.wash_sale_exposure tax.realized_gains],
    "options_desk" => %w[options.summary options.expiring options.premium_income options.contract_ledger options.underlying_concentration],
    "research_desk" => %w[research.priority_watchlist research.portfolio_news research.upcoming_events review.source_health research.freshness],
    "account_portfolio_review" => %w[portfolio.holdings_concentration portfolio.allocation portfolio.top_holdings review.data_quality income.summary research.portfolio_news],
    "blank" => []
  }.freeze

  test "registers exactly eight canonical investment workflow widgets" do
    assert_equal %w[
      investments.decision_center investments.holdings investments.income_performance
      investments.tax_workspace investments.options investments.market_events
      investments.watchlist investments.news
    ], Dashboard::WidgetRegistry.investment_keys
  end

  test "templates contain only unique registered widgets within the page limit" do
    assert_equal EXPECTED.keys, Dashboard::PageTemplateRegistry.all.map(&:key)
    assert_equal Dashboard::WidgetRegistry.investment_keys, Dashboard::PageTemplateRegistry.fetch("investment_workspaces").widget_keys

    EXPECTED.each do |key, widget_keys|
      template = Dashboard::PageTemplateRegistry.fetch(key)
      assert_equal widget_keys, template.widget_keys
      assert_equal widget_keys.uniq, widget_keys
      assert_operator widget_keys.size, :<=, User::MAX_DASHBOARD_WIDGETS
      assert widget_keys.all? { |widget_key| Dashboard::WidgetRegistry.registered?(widget_key) }
    end
  end

  test "legacy widget keys resolve to canonical workflows" do
    assert_equal "investments.decision_center", Dashboard::WidgetRegistry.fetch("investments.decision_pulse").key
    assert_equal "investments.holdings", Dashboard::WidgetRegistry.fetch("investments.holdings_data_quality").key
    assert_equal "investments.income_performance", Dashboard::WidgetRegistry.fetch("investments.income_cash_flows").key
  end
end
