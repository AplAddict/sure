module Dashboard
  class PageTemplateRegistry
    Widget = Data.define(:key, :settings, :layout) do
      def initialize(key:, settings: {}, layout: {})
        super(key: key, settings: settings.stringify_keys.freeze, layout: layout.stringify_keys.freeze)
      end
    end

    Template = Data.define(:key, :name, :widgets, :visible, :account_scoped) do
      def widget_keys = widgets.map(&:key)
      def account_scoped? = account_scoped
    end

    class << self
      def widget(key, settings: {}, layout: {})
        Widget.new(key: key, settings: settings, layout: layout)
      end

      def template(key, name, keys, visible: true, account_scoped: false)
        Template.new(key: key, name: name, widgets: keys.map { |item| item.is_a?(Widget) ? item : widget(item) }.freeze, visible: visible, account_scoped: account_scoped)
      end
    end

    TEMPLATES = [
      # One decision-first surface. Detailed tax/options/events workflows remain
      # available in their own templates and canonical workspaces rather than
      # duplicating their summaries on the daily page.
      template("daily_investment_check", "Daily Investment Check", [ "portfolio.pulse", "review.needs_review", "portfolio.day_movers", "portfolio.cash_liquidity", "portfolio.largest_position", widget("research.news", settings: { filter: "sentiment" }) ]),
      template("portfolio_review", "Portfolio Review", [ "portfolio.largest_position", widget("portfolio.allocation", settings: { grouping: "asset_class" }), widget("portfolio.allocation", settings: { grouping: "sector" }), "portfolio.top_holdings", "review.data_quality", widget("income.summary", settings: { period: "1y" }) ]),
      template("income_risk", "Income & Risk", [ widget("income.summary", settings: { period: "1y" }), "income.by_type", "income.top_months", "income.cash_flows", "income.return_risk", "income.fx_gaps" ]),
      template("tax_review", "Tax Review", %w[tax.lot_coverage tax.term_split tax.long_term_window tax.harvest_loss_total tax.harvest_candidates tax.fx_unavailable]),
      template("options_desk", "Options Desk", %w[options.summary options.expiration_window options.dte_distribution options.premium_income options.by_underlying options.unmeasured]),
      template("research_desk", "Research Desk", [ widget("research.watchlist_snapshot", settings: { display: "price" }), widget("research.news", settings: { filter: "sentiment" }), "research.event_countdown", "review.source_health", "research.freshness" ]),
      template("account_portfolio_review", "Account Portfolio Review", [ "portfolio.largest_position", widget("portfolio.allocation", settings: { grouping: "asset_class" }), "portfolio.top_holdings", "review.data_quality", widget("income.summary", settings: { period: "1y" }), widget("research.news", settings: { filter: "sentiment" }) ], account_scoped: true),
      template("blank", "Blank Page", []),
      template("investment_workspaces", "Investment workspaces", WidgetRegistry.investment_keys, visible: false)
    ].freeze

    INDEX = TEMPLATES.index_by(&:key).freeze

    class << self
      def all = TEMPLATES.select(&:visible)
      def keys = INDEX.keys
      def fetch(key) = INDEX.fetch(key.to_s)
      def find(key) = INDEX[key.to_s]

      def validate!
        TEMPLATES.each do |template|
          raise ArgumentError, "unknown widget in #{template.key}" unless template.widget_keys.all? { |key| WidgetRegistry.registered?(key) }
          raise ArgumentError, "template exceeds widget limit" if template.widgets.size > DashboardPageConfigurable::MAX_DASHBOARD_WIDGETS

          template.widgets.each do |widget|
            definition = WidgetRegistry.fetch(widget.key)
            definition.normalize_settings!(widget.settings, user: ValidationUser.new)
            layout = { "col_width" => definition.default_col_width, "height" => definition.default_height }.merge(widget.layout)
            raise ArgumentError, "unsupported template width" unless definition.supported_col_widths.include?(layout.fetch("col_width"))
            raise ArgumentError, "unsupported template height" unless definition.supported_heights.include?(layout.fetch("height"))
          end
        end
      end
    end

    # Registry templates currently use defaults only. This fail-closed stand-in
    # keeps validation independent of request state and rejects any future scoped
    # identifier until template application validates it for the actual member.
    class ValidationUser
      def accessible_accounts = Account.none
      def research_watchlist_entries = ResearchWatchlistEntry.none
    end

    validate!
  end
end
