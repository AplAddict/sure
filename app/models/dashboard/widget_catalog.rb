module Dashboard
  # Presentation metadata for every WidgetRegistry key. The registry remains the
  # authority for access, settings and layout; this catalog owns labels,
  # grouping, compact renderers and canonical expansion routes.
  class WidgetCatalog
    Entry = Data.define(:key, :legacy_key, :title_key, :partial, :padded, :canonical_route, :group) do
      def description_key = "pages.dashboard.widget_catalog.#{key.tr('.', '_')}"
    end

    class << self
      def entry(key, title: nil, partial: "pages/dashboard/investment_widgets/granular", padded: true, route: nil, group:)
        Entry.new(
          key: key,
          legacy_key: key.start_with?("home.") ? key.delete_prefix("home.") : key.tr(".", "_"),
          title_key: title || "pages.dashboard.granular_widgets.#{key.tr('.', '_')}",
          partial: partial,
          padded: padded,
          canonical_route: route,
          group: group
        )
      end
    end

    ENTRIES = [
      entry("home.insights_feed", title: "pages.dashboard.insights_feed.title", partial: "pages/dashboard/insights_feed", padded: false, route: :insights, group: :review),
      entry("home.cashflow_sankey", title: "pages.dashboard.cashflow_sankey.title", partial: "pages/dashboard/cashflow_sankey", padded: false, group: :home_cash_flow),
      entry("home.money_flow", title: "pages.dashboard.money_flow.title", partial: "pages/dashboard/money_flow", padded: false, group: :home_cash_flow),
      entry("home.spending_trend", title: "pages.dashboard.spending_trend.title", partial: "pages/dashboard/spending_trend", padded: false, group: :home_cash_flow),
      entry("home.outflows_donut", title: "pages.dashboard.outflows_donut.title", partial: "pages/dashboard/outflows_donut", padded: false, group: :home_cash_flow),
      entry("home.investment_summary", title: "pages.dashboard.investment_summary.title", partial: "pages/dashboard/investment_summary", padded: false, route: :portfolio_holdings, group: :portfolio),
      entry("home.net_worth_chart", title: "pages.dashboard.net_worth_chart.title", partial: "pages/dashboard/net_worth_chart", padded: false, group: :home_cash_flow),
      entry("home.balance_sheet", title: "pages.dashboard.balance_sheet.title", partial: "pages/dashboard/balance_sheet", padded: false, group: :home_cash_flow),

      entry("investments.decision_center", title: "pages.dashboard.investment_widgets.decision_center", partial: "pages/dashboard/investment_widgets/decision_center", route: :investment_decision, group: :review),
      entry("investments.holdings", title: "pages.dashboard.investment_widgets.holdings", partial: "pages/dashboard/investment_widgets/holdings", route: :portfolio_holdings, group: :portfolio),
      entry("investments.income_performance", title: "pages.dashboard.investment_widgets.income_performance", partial: "pages/dashboard/investment_widgets/income_performance", route: :investment_income, group: :income),
      entry("investments.tax_workspace", title: "pages.dashboard.investment_widgets.tax_workspace", partial: "pages/dashboard/investment_widgets/tax_workspace", route: :tax_lot_review, group: :tax),
      entry("investments.options", title: "pages.dashboard.investment_widgets.options", partial: "pages/dashboard/investment_widgets/options", route: :options_review, group: :options),
      entry("investments.market_events", title: "pages.dashboard.investment_widgets.market_events", partial: "pages/dashboard/investment_widgets/market_events", route: :market_events, group: :market),
      entry("investments.watchlist", title: "pages.dashboard.investment_widgets.watchlist", partial: "pages/dashboard/investment_widgets/watchlist", route: :research_watchlist_entries, group: :research),
      entry("research.news", title: "pages.dashboard.ticker_news.title", partial: "pages/dashboard/ticker_news", padded: false, route: :research_news, group: :research),

      entry("portfolio.pulse", route: :investment_decision, group: :portfolio),
      entry("review.needs_review", route: :investment_decision, group: :review),
      entry("review.source_health", route: :investment_decision, group: :review),
      entry("portfolio.allocation", route: :portfolio_holdings, group: :portfolio),
      entry("portfolio.top_holdings", route: :portfolio_holdings, group: :portfolio),
      entry("review.data_quality", route: :portfolio_holdings, group: :review),
      entry("portfolio.security_snapshot", route: :portfolio_holdings, group: :portfolio),
      entry("income.summary", route: :investment_income, group: :income),
      entry("income.monthly", route: :investment_income, group: :income),
      entry("income.cash_flows", route: :investment_income, group: :income),
      entry("income.return_risk", route: :investment_income, group: :income),
      entry("tax.realized_gains", route: :tax_lot_review, group: :tax),
      entry("tax.lot_coverage", route: :tax_lot_review, group: :tax),
      entry("tax.harvest_summary", route: :tax_loss_harvest, group: :tax),
      entry("tax.harvest_candidates", route: :tax_loss_harvest, group: :tax),
      entry("tax.wash_sale_exposure", route: :tax_loss_harvest, group: :tax),
      entry("options.summary", route: :options_review, group: :options),
      entry("options.premium_income", route: :investment_income, group: :options),
      entry("options.contract_ledger", route: :options_review, group: :options),
      entry("research.freshness", group: :research),

      entry("portfolio.day_movers", route: :portfolio_holdings, group: :portfolio),
      entry("portfolio.largest_position", route: :portfolio_holdings, group: :portfolio),
      entry("portfolio.account_balances", route: :portfolio_holdings, group: :portfolio),
      entry("portfolio.cash_liquidity", route: :portfolio_holdings, group: :portfolio),
      entry("portfolio.holdings_count", route: :portfolio_holdings, group: :portfolio),
      entry("income.by_type", route: :investment_income, group: :income),
      entry("income.top_months", route: :investment_income, group: :income),
      entry("income.fx_gaps", route: :investment_income, group: :income),
      entry("tax.term_split", route: :tax_lot_review, group: :tax),
      entry("tax.unrealized_by_holding", route: :tax_lot_review, group: :tax),
      entry("tax.harvest_loss_total", route: :tax_loss_harvest, group: :tax),
      entry("tax.fx_unavailable", route: :tax_loss_harvest, group: :tax),
      entry("tax.long_term_window", route: :tax_lot_review, group: :tax),
      entry("options.expiration_window", route: :options_review, group: :options),
      entry("options.dte_distribution", route: :options_review, group: :options),
      entry("options.by_underlying", route: :options_review, group: :options),
      entry("options.unmeasured", route: :options_review, group: :options),
      entry("research.watchlist_snapshot", route: :research_watchlist_entries, group: :research),
      entry("research.event_countdown", route: :market_events, group: :research)
    ].freeze

    INDEX = ENTRIES.index_by(&:key).freeze
    HEIGHT_PX = { 3 => 208, 4 => 288, 5 => 352, 6 => 416 }.freeze
    HEIGHT_PRESETS = { 3 => "compact", 4 => "auto", 5 => "medium", 6 => "tall" }.freeze
    GROUPS = %i[portfolio review income tax options research market home_cash_flow].freeze

    class << self
      def fetch(key) = INDEX.fetch(WidgetRegistry.canonical_key(key))
      def find(key) = INDEX[WidgetRegistry.canonical_key(key)]
      def height_px(units) = HEIGHT_PX.fetch(units.to_i) { HEIGHT_PX.fetch(4) }
      def height_preset(units) = HEIGHT_PRESETS.fetch(units.to_i) { "auto" }
    end
  end
end
