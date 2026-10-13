require "test_helper"

class Dashboard::WidgetRegistryTest < ActiveSupport::TestCase
  NEW_WIDGET_KEYS = %w[
    portfolio.day_movers portfolio.allocation portfolio.largest_position
    portfolio.account_balances portfolio.cash_liquidity portfolio.holdings_count
    income.by_type income.top_months income.fx_gaps
    tax.term_split tax.unrealized_by_holding tax.harvest_loss_total tax.fx_unavailable
    tax.long_term_window options.expiration_window options.dte_distribution
    options.by_underlying options.unmeasured research.watchlist_snapshot
    research.event_countdown research.news
  ].freeze

  test "registry exposes authoritative metadata without loaders" do
    expected_workspaces = %w[
      investments.decision_center investments.holdings investments.income_performance
      investments.tax_workspace investments.options investments.market_events
      investments.watchlist research.news
    ]
    expected_granular = %w[
      portfolio.pulse review.needs_review review.source_health
      portfolio.top_holdings portfolio.allocation
      review.data_quality portfolio.security_snapshot income.summary income.monthly
      income.cash_flows income.return_risk options.premium_income tax.realized_gains
      tax.lot_coverage tax.harvest_summary tax.harvest_candidates
      tax.wash_sale_exposure options.summary options.expiration_window options.premium_income
      options.contract_ledger options.by_underlying research.watchlist_snapshot
      research.news research.event_countdown research.freshness
    ]

    assert_equal expected_workspaces, Dashboard::WidgetRegistry.investment_keys
    assert_empty expected_granular - Dashboard::WidgetRegistry.keys
    assert_equal 55, Dashboard::WidgetRegistry.keys.size
    assert_empty NEW_WIDGET_KEYS - Dashboard::WidgetRegistry.keys
    Dashboard::WidgetRegistry.all.each do |definition|
      catalog = Dashboard::WidgetCatalog.fetch(definition.key)
      assert definition.key.present?
      assert catalog.group.present?
      assert catalog.partial.present?
      assert I18n.exists?(catalog.title_key), "missing title for #{definition.key}"
      assert I18n.exists?(catalog.description_key), "missing description for #{definition.key}"
      assert_includes definition.supported_col_widths, definition.default_col_width
      assert_includes definition.supported_heights, definition.default_height
      assert_equal definition.supported_col_widths.uniq, definition.supported_col_widths
      assert_equal definition.supported_heights.uniq, definition.supported_heights
      assert_includes [ true, false ], definition.investment_required
      assert definition.load_group.present?
    end
  end

  test "every live widget has exactly one title and description locale key" do
    live_titles = Dashboard::WidgetCatalog::ENTRIES.filter_map do |entry|
      entry.title_key.delete_prefix("pages.dashboard.granular_widgets.") if entry.title_key.start_with?("pages.dashboard.granular_widgets.")
    end.sort
    live_descriptions = Dashboard::WidgetCatalog::ENTRIES.map { |entry| entry.description_key.delete_prefix("pages.dashboard.widget_catalog.") }.sort

    assert_equal live_titles, I18n.t("pages.dashboard.granular_widgets").keys.map(&:to_s).sort
    assert_equal live_descriptions, I18n.t("pages.dashboard.widget_catalog").keys.map(&:to_s).sort
  end

  test "news variants resolve to one canonical configurable definition" do
    legacy_keys = %w[home.ticker_news investments.news research.portfolio_news research.news_sentiment]
    news = Dashboard::WidgetRegistry.fetch("research.news")

    assert_equal [ "research.news" ], Dashboard::WidgetRegistry.keys.grep(/news/)
    assert_equal %w[scope account_id security_id period rows sort filter density sentiment], news.settings.keys
    legacy_keys.each { |key| assert_same news, Dashboard::WidgetRegistry.fetch(key) }
    assert_equal "sentiment", news.normalize_settings!({ "rows" => 8 }, user: users(:family_admin), legacy_key: "research.news_sentiment").fetch("filter")
    assert_equal "newest", news.normalize_settings!({ "sort" => "latest" }, user: users(:family_admin), legacy_key: "research.portfolio_news").fetch("sort")
  end

  test "variant aliases migrate to canonical settings without losing supported choices" do
    user = users(:family_admin)

    assert_equal "sector", Dashboard::WidgetRegistry.fetch("portfolio.sector_exposure")
      .normalize_settings!({ "rows" => 8 }, user: user, legacy_key: "portfolio.sector_exposure").fetch("grouping")
    assert_equal "1y", Dashboard::WidgetRegistry.fetch("income.trailing_12_month")
      .normalize_settings!({ "scope" => "overall" }, user: user, legacy_key: "income.trailing_12_month").fetch("period")
    assert_equal "options.premium_income", Dashboard::WidgetRegistry.fetch("income.options_premium").key
    assert_equal "options.expiration_window", Dashboard::WidgetRegistry.fetch("options.expiring").key
    assert_equal "research.watchlist_snapshot", Dashboard::WidgetRegistry.fetch("research.priority_watchlist").key
  end

  test "every setting has localized label help and enum options" do
    Dashboard::WidgetRegistry.all.each do |definition|
      definition.settings.each_value do |setting|
        assert I18n.exists?("pages.dashboard.settings.labels.#{setting.key}"), "missing label for #{definition.key}.#{setting.key}"
        assert I18n.exists?("pages.dashboard.settings.help.#{setting.key}"), "missing help for #{definition.key}.#{setting.key}"
        Array(setting.values).each do |value|
          assert I18n.exists?("pages.dashboard.settings.options.#{setting.key}.#{value}"), "missing option for #{definition.key}.#{setting.key}=#{value}"
        end
      end
    end
  end

  test "research widgets only link to workspaces that show their evidence" do
    assert_nil Dashboard::WidgetCatalog.fetch("research.freshness").canonical_route
    assert_equal :market_events, Dashboard::WidgetCatalog.fetch("research.event_countdown").canonical_route
  end

  test "registry declares resize capabilities per widget" do
    resizable = Dashboard::WidgetRegistry.fetch("home.spending_trend")
    fixed = Dashboard::WidgetRegistry.fetch("home.outflows_donut")

    assert_equal [ 6, 12 ], resizable.supported_col_widths
    assert_equal [ 3, 4, 6 ], resizable.supported_heights
    assert_equal [ fixed.default_col_width ], fixed.supported_col_widths
    assert_equal [ fixed.default_height ], fixed.supported_heights
  end

  test "new bounded settings reject values outside their contracts" do
    expiration = Dashboard::WidgetRegistry.fetch("options.expiration_window")
    long_term = Dashboard::WidgetRegistry.fetch("tax.long_term_window")

    assert_equal %w[7 14 30], expiration.settings.fetch("window").values
    assert_equal %w[30 60 90], long_term.settings.fetch("window").values
    assert_raises(User::DashboardPagesValidationError) { expiration.normalize_settings!({ "window" => "31" }, user: users(:family_admin)) }
    assert_raises(User::DashboardPagesValidationError) { long_term.normalize_settings!({ "rows" => 13 }, user: users(:family_admin)) }
  end

  test "registry settings contracts expose exact defaults and constraints" do
    definition = Dashboard::WidgetRegistry.fetch("portfolio.allocation")

    assert_equal %w[scope account_id rows grouping], definition.settings.keys
    assert_equal "overall", definition.default_settings.fetch("scope")
    assert_nil definition.default_settings.fetch("account_id")
    assert_equal 5, definition.default_settings.fetch("rows")
    assert_equal %w[asset_class sector region security account], definition.settings.fetch("grouping").values
  end
end
