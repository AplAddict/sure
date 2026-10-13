require "test_helper"

class Dashboard::WidgetRegistryTest < ActiveSupport::TestCase
  test "registry exposes authoritative metadata without loaders" do
    expected_workspaces = %w[
      investments.decision_center investments.holdings investments.income_performance
      investments.tax_workspace investments.options investments.market_events
      investments.watchlist investments.news
    ]
    expected_granular = %w[
      portfolio.pulse review.needs_review review.source_health
      portfolio.holdings_concentration portfolio.allocation portfolio.top_holdings
      review.data_quality portfolio.security_snapshot income.summary income.monthly
      income.cash_flows income.return_risk income.options_premium tax.realized_gains
      tax.lot_coverage tax.nearing_long_term tax.harvest_summary tax.harvest_candidates
      tax.wash_sale_exposure options.summary options.expiring options.premium_income
      options.contract_ledger options.underlying_concentration research.priority_watchlist
      research.portfolio_news research.upcoming_events research.freshness
    ]

    assert_equal expected_workspaces, Dashboard::WidgetRegistry.investment_keys
    assert_empty expected_granular - Dashboard::WidgetRegistry.keys
    assert_operator Dashboard::WidgetRegistry.keys.size, :>=, 40
    Dashboard::WidgetRegistry.all.each do |definition|
      assert definition.key.present?
      assert_includes definition.supported_col_widths, definition.default_col_width
      assert_includes definition.supported_heights, definition.default_height
      assert_equal definition.supported_col_widths.uniq, definition.supported_col_widths
      assert_equal definition.supported_heights.uniq, definition.supported_heights
      assert_includes [ true, false ], definition.investment_required
      assert definition.load_group.present?
    end
  end

  test "registry declares resize capabilities per widget" do
    resizable = Dashboard::WidgetRegistry.fetch("home.spending_trend")
    fixed = Dashboard::WidgetRegistry.fetch("home.outflows_donut")

    assert_equal [ 6, 12 ], resizable.supported_col_widths
    assert_equal [ 3, 4, 6 ], resizable.supported_heights
    assert_equal [ fixed.default_col_width ], fixed.supported_col_widths
    assert_equal [ fixed.default_height ], fixed.supported_heights
  end

  test "registry settings contracts expose exact defaults and constraints" do
    definition = Dashboard::WidgetRegistry.fetch("portfolio.allocation")

    assert_equal %w[scope account_id rows grouping], definition.settings.keys
    assert_equal "overall", definition.default_settings.fetch("scope")
    assert_nil definition.default_settings.fetch("account_id")
    assert_equal 5, definition.default_settings.fetch("rows")
    assert_equal %w[asset_class sector security account], definition.settings.fetch("grouping").values
  end
end
