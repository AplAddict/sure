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
      template("daily_investment_check", "Daily Investment Check", %w[portfolio.pulse review.needs_review review.source_health options.expiring tax.harvest_candidates research.upcoming_events research.portfolio_news]),
      template("portfolio_review", "Portfolio Review", %w[portfolio.holdings_concentration portfolio.allocation portfolio.top_holdings review.data_quality income.summary research.portfolio_news]),
      template("income_risk", "Income & Risk", %w[income.summary income.monthly income.cash_flows income.return_risk tax.realized_gains income.options_premium]),
      template("tax_review", "Tax Review", %w[tax.lot_coverage tax.nearing_long_term tax.harvest_summary tax.harvest_candidates tax.wash_sale_exposure tax.realized_gains]),
      template("options_desk", "Options Desk", %w[options.summary options.expiring options.premium_income options.contract_ledger options.underlying_concentration]),
      template("research_desk", "Research Desk", %w[research.priority_watchlist research.portfolio_news research.upcoming_events review.source_health research.freshness]),
      template("account_portfolio_review", "Account Portfolio Review", %w[portfolio.holdings_concentration portfolio.allocation portfolio.top_holdings review.data_quality income.summary research.portfolio_news], account_scoped: true),
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
