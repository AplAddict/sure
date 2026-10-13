module Dashboard
  # Presentation metadata for every WidgetRegistry key: how a widget is titled
  # and described, which partial draws it, how its card pads the content, and
  # (for investment widgets) the canonical workspace page it links to when it
  # cannot be rendered. The registry stays the authority on keys, layouts and
  # access; this only says how a registered widget looks on a dashboard page.
  class WidgetCatalog
    Entry = Data.define(:key, :legacy_key, :title_key, :partial, :padded, :canonical_route) do
      # Translation key for the add-widget dialog blurb.
      def description_key = "pages.dashboard.widget_catalog.#{key.tr(".", "_")}"
    end

    ENTRIES = [
      Entry.new(key: "home.ticker_news", legacy_key: "ticker_news", title_key: "pages.dashboard.ticker_news.title", partial: "pages/dashboard/ticker_news", padded: false, canonical_route: :research_news),
      Entry.new(key: "home.insights_feed", legacy_key: "insights_feed", title_key: "pages.dashboard.insights_feed.title", partial: "pages/dashboard/insights_feed", padded: false, canonical_route: :insights),
      Entry.new(key: "home.cashflow_sankey", legacy_key: "cashflow_sankey", title_key: "pages.dashboard.cashflow_sankey.title", partial: "pages/dashboard/cashflow_sankey", padded: false, canonical_route: nil),
      Entry.new(key: "home.money_flow", legacy_key: "money_flow", title_key: "pages.dashboard.money_flow.title", partial: "pages/dashboard/money_flow", padded: false, canonical_route: nil),
      Entry.new(key: "home.spending_trend", legacy_key: "spending_trend", title_key: "pages.dashboard.spending_trend.title", partial: "pages/dashboard/spending_trend", padded: false, canonical_route: nil),
      Entry.new(key: "home.outflows_donut", legacy_key: "outflows_donut", title_key: "pages.dashboard.outflows_donut.title", partial: "pages/dashboard/outflows_donut", padded: false, canonical_route: nil),
      Entry.new(key: "home.investment_summary", legacy_key: "investment_summary", title_key: "pages.dashboard.investment_summary.title", partial: "pages/dashboard/investment_summary", padded: false, canonical_route: :portfolio_holdings),
      Entry.new(key: "home.net_worth_chart", legacy_key: "net_worth_chart", title_key: "pages.dashboard.net_worth_chart.title", partial: "pages/dashboard/net_worth_chart", padded: false, canonical_route: nil),
      Entry.new(key: "home.balance_sheet", legacy_key: "balance_sheet", title_key: "pages.dashboard.balance_sheet.title", partial: "pages/dashboard/balance_sheet", padded: false, canonical_route: nil),
      Entry.new(key: "investments.decision_pulse", legacy_key: "decision_pulse", title_key: "investment_decision_center.pulse.heading", partial: "pages/decision_center/pulse", padded: true, canonical_route: :portfolio_holdings),
      Entry.new(key: "investments.decision_action", legacy_key: "decision_action", title_key: "investment_decision_center.actions.heading", partial: "pages/decision_center/actions", padded: false, canonical_route: :tax_lot_review),
      Entry.new(key: "investments.decision_monitor", legacy_key: "decision_monitor", title_key: "investment_decision_center.monitor.heading", partial: "pages/decision_center/monitor", padded: false, canonical_route: :portfolio_holdings),
      Entry.new(key: "investments.holdings_allocation", legacy_key: "holdings_allocation", title_key: "portfolio_holdings.allocation_section", partial: "portfolio_holdings/allocation_section", padded: true, canonical_route: :portfolio_holdings),
      Entry.new(key: "investments.holdings_data_quality", legacy_key: "holdings_data_quality", title_key: "portfolio_holdings.data_quality_section", partial: "portfolio_holdings/data_quality_section", padded: true, canonical_route: :portfolio_holdings),
      Entry.new(key: "investments.income_performance", legacy_key: "income_performance", title_key: "investment_incomes.show.performance", partial: "investment_incomes/performance", padded: true, canonical_route: :investment_income),
      Entry.new(key: "investments.income_cash_flows", legacy_key: "income_cash_flows", title_key: "investment_incomes.show.cash_flows", partial: "investment_incomes/cash_flows", padded: true, canonical_route: :investment_income)
    ].freeze

    INDEX = ENTRIES.index_by(&:key).freeze

    # Pixel heights for the registry's height units; grow widgets (charts)
    # fill this via the --dash-widget-h CSS variable. 3/4/6 are the legacy
    # compact/auto/tall presets so migrated layouts keep their exact size.
    HEIGHT_PX = { 3 => 208, 4 => 288, 5 => 352, 6 => 416 }.freeze
    HEIGHT_PRESETS = { 3 => "compact", 4 => "auto", 5 => "medium", 6 => "tall" }.freeze

    class << self
      def fetch(key) = INDEX.fetch(key.to_s)
      def find(key) = INDEX[key.to_s]

      def height_px(units) = HEIGHT_PX.fetch(units.to_i) { HEIGHT_PX.fetch(4) }
      def height_preset(units) = HEIGHT_PRESETS.fetch(units.to_i) { "auto" }
    end
  end
end
