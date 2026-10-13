module Dashboard
  class WidgetRegistry
    Definition = Data.define(
      :key,
      :default_col_width,
      :default_height,
      :supported_col_widths,
      :supported_heights,
      :investment_required,
      :load_group
    ) do
      def as_json(*)
        to_h.stringify_keys
      end
    end

    DEFINITIONS = [
      Definition.new(key: "home.ticker_news", default_col_width: 12, default_height: 3, supported_col_widths: [ 6, 12 ], supported_heights: [ 3 ], investment_required: false, load_group: "home_news"),
      Definition.new(key: "home.insights_feed", default_col_width: 12, default_height: 3, supported_col_widths: [ 6, 12 ], supported_heights: [ 3 ], investment_required: false, load_group: "home_insights"),
      Definition.new(key: "home.cashflow_sankey", default_col_width: 12, default_height: 6, supported_col_widths: [ 6, 12 ], supported_heights: [ 6 ], investment_required: false, load_group: "home_cashflow"),
      Definition.new(key: "home.money_flow", default_col_width: 6, default_height: 4, supported_col_widths: [ 6, 12 ], supported_heights: [ 4 ], investment_required: false, load_group: "home_cashflow"),
      Definition.new(key: "home.spending_trend", default_col_width: 6, default_height: 4, supported_col_widths: [ 6, 12 ], supported_heights: [ 3, 4, 6 ], investment_required: false, load_group: "home_cashflow"),
      Definition.new(key: "home.outflows_donut", default_col_width: 6, default_height: 4, supported_col_widths: [ 6 ], supported_heights: [ 4 ], investment_required: false, load_group: "home_cashflow"),
      Definition.new(key: "home.investment_summary", default_col_width: 6, default_height: 4, supported_col_widths: [ 6, 12 ], supported_heights: [ 4 ], investment_required: true, load_group: "home_investments"),
      Definition.new(key: "home.net_worth_chart", default_col_width: 6, default_height: 4, supported_col_widths: [ 6, 12 ], supported_heights: [ 3, 4, 6 ], investment_required: false, load_group: "home_net_worth"),
      Definition.new(key: "home.balance_sheet", default_col_width: 6, default_height: 4, supported_col_widths: [ 6, 12 ], supported_heights: [ 4 ], investment_required: false, load_group: "home_net_worth"),
      Definition.new(key: "investments.decision_pulse", default_col_width: 6, default_height: 4, supported_col_widths: [ 6 ], supported_heights: [ 4 ], investment_required: true, load_group: "investment_decision"),
      Definition.new(key: "investments.decision_action", default_col_width: 6, default_height: 4, supported_col_widths: [ 6 ], supported_heights: [ 4 ], investment_required: true, load_group: "investment_decision"),
      Definition.new(key: "investments.decision_monitor", default_col_width: 12, default_height: 5, supported_col_widths: [ 12 ], supported_heights: [ 5 ], investment_required: true, load_group: "investment_decision"),
      Definition.new(key: "investments.holdings_allocation", default_col_width: 6, default_height: 5, supported_col_widths: [ 6 ], supported_heights: [ 5 ], investment_required: true, load_group: "investment_holdings"),
      Definition.new(key: "investments.holdings_data_quality", default_col_width: 6, default_height: 4, supported_col_widths: [ 6 ], supported_heights: [ 4 ], investment_required: true, load_group: "investment_holdings"),
      Definition.new(key: "investments.income_performance", default_col_width: 6, default_height: 4, supported_col_widths: [ 6 ], supported_heights: [ 4 ], investment_required: true, load_group: "investment_income"),
      Definition.new(key: "investments.income_cash_flows", default_col_width: 6, default_height: 4, supported_col_widths: [ 6 ], supported_heights: [ 4 ], investment_required: true, load_group: "investment_income")
    ].freeze

    INDEX = DEFINITIONS.index_by(&:key).freeze

    class << self
      def all = DEFINITIONS
      def keys = INDEX.keys
      def fetch(key) = INDEX.fetch(key.to_s)
      def find(key) = INDEX[key.to_s]
      def registered?(key) = INDEX.key?(key.to_s)
    end
  end
end
