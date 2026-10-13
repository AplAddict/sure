require "test_helper"

class DashboardPageTemplateRegistryTest < ActiveSupport::TestCase
  EXPECTED = {
    "daily_investment_check" => %w[portfolio.pulse review.needs_review portfolio.day_movers portfolio.cash_liquidity portfolio.largest_position research.news],
    "portfolio_review" => %w[portfolio.largest_position portfolio.allocation portfolio.allocation portfolio.top_holdings review.data_quality income.summary],
    "income_risk" => %w[income.summary income.by_type income.top_months income.cash_flows income.return_risk income.fx_gaps],
    "tax_review" => %w[tax.lot_coverage tax.term_split tax.long_term_window tax.harvest_loss_total tax.harvest_candidates tax.fx_unavailable],
    "options_desk" => %w[options.summary options.expiration_window options.dte_distribution options.premium_income options.by_underlying options.unmeasured],
    "research_desk" => %w[research.watchlist_snapshot research.news research.event_countdown review.source_health research.freshness],
    "account_portfolio_review" => %w[portfolio.largest_position portfolio.allocation portfolio.top_holdings review.data_quality income.summary research.news],
    "blank" => []
  }.freeze

  test "registers exactly eight canonical investment workflow widgets" do
    assert_equal %w[
      investments.decision_center investments.holdings investments.income_performance
      investments.tax_workspace investments.options investments.market_events
      investments.watchlist research.news
    ], Dashboard::WidgetRegistry.investment_keys
  end

  test "templates contain only registered setting-distinct widgets within the page limit" do
    assert_equal EXPECTED.keys, Dashboard::PageTemplateRegistry.all.map(&:key)
    assert_equal Dashboard::WidgetRegistry.investment_keys, Dashboard::PageTemplateRegistry.fetch("investment_workspaces").widget_keys

    EXPECTED.each do |key, widget_keys|
      template = Dashboard::PageTemplateRegistry.fetch(key)
      assert_equal widget_keys, template.widget_keys
      assert_equal template.widgets.map { |widget| [ widget.key, widget.settings ] }.uniq, template.widgets.map { |widget| [ widget.key, widget.settings ] }
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
