require "test_helper"

class Dashboard::WidgetRegistryTest < ActiveSupport::TestCase
  test "registry exposes authoritative metadata without loaders" do
    expected = %w[
      home.ticker_news home.insights_feed home.cashflow_sankey home.money_flow
      home.spending_trend home.outflows_donut home.investment_summary
      home.net_worth_chart home.balance_sheet investments.decision_pulse
      investments.decision_action investments.decision_monitor
      investments.holdings_allocation investments.holdings_data_quality
      investments.income_performance investments.income_cash_flows
    ]

    assert_equal expected.sort, Dashboard::WidgetRegistry.keys.sort
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
end
