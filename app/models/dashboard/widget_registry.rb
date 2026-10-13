module Dashboard
  class WidgetRegistry
    Setting = Data.define(:key, :type, :default, :values, :minimum, :maximum) do
      def as_json(*)
        to_h.compact.stringify_keys
      end
    end

    Definition = Data.define(
      :key,
      :default_col_width,
      :default_height,
      :supported_col_widths,
      :supported_heights,
      :investment_required,
      :load_group,
      :settings
    ) do
      def as_json(*)
        to_h.except(:settings).merge(
          settings: settings.transform_values(&:as_json),
          default_settings: default_settings
        ).stringify_keys
      end

      def default_settings
        settings.transform_values(&:default)
      end

      def normalize_settings!(raw, user:)
        value = raw.nil? ? {} : raw
        raise DashboardPageConfigurable::DashboardPagesValidationError, "settings must be an object" unless value.is_a?(Hash)

        supplied = value.stringify_keys
        unknown = supplied.keys - settings.keys
        raise DashboardPageConfigurable::DashboardPagesValidationError, "unknown widget settings: #{unknown.join(', ')}" if unknown.any?

        normalized = default_settings.merge(supplied)
        settings.each_value do |setting|
          normalized[setting.key] = nil if setting.type == "identifier" && normalized[setting.key].blank?
        end
        settings.each_value { |setting| validate_setting!(setting, normalized.fetch(setting.key)) }
        validate_scope!(normalized, user)
        normalized
      end

      private
        def validate_setting!(setting, value)
          case setting.type
          when "enum"
            unless value.is_a?(String) && setting.values.include?(value)
              raise DashboardPageConfigurable::DashboardPagesValidationError, "#{setting.key} is not supported for #{key}"
            end
          when "integer"
            unless value.is_a?(Integer) && value.between?(setting.minimum, setting.maximum)
              raise DashboardPageConfigurable::DashboardPagesValidationError, "#{setting.key} is not valid for #{key}"
            end
          when "identifier"
            unless value.nil? || value.is_a?(String)
              raise DashboardPageConfigurable::DashboardPagesValidationError, "#{setting.key} must be an identifier or null"
            end
          else
            raise DashboardPageConfigurable::DashboardPagesValidationError, "invalid settings contract for #{key}"
          end
        end

        def validate_scope!(normalized, user)
          return unless normalized.key?("scope")

          account_id = normalized["account_id"]
          security_id = normalized["security_id"]
          case normalized.fetch("scope")
          when "overall"
            reject_scope_identifier!(account_id, "account_id")
            reject_scope_identifier!(security_id, "security_id")
          when "account"
            raise DashboardPageConfigurable::DashboardPagesValidationError, "account_id is required" if account_id.blank?
            reject_scope_identifier!(security_id, "security_id")
            unless user.accessible_accounts.visible.where(accountable_type: %w[Investment Crypto]).exists?(id: account_id)
              raise DashboardPageConfigurable::DashboardPagesValidationError, "account is not accessible"
            end
          when "security"
            raise DashboardPageConfigurable::DashboardPagesValidationError, "security_id is required" if security_id.blank?
            reject_scope_identifier!(account_id, "account_id")
            unless accessible_security_ids(user).include?(security_id)
              raise DashboardPageConfigurable::DashboardPagesValidationError, "security is not accessible"
            end
          end
        end

        def reject_scope_identifier!(value, name)
          raise DashboardPageConfigurable::DashboardPagesValidationError, "#{name} is not valid for this scope" if value.present?
        end

        def accessible_security_ids(user)
          held = Holding.where(account_id: user.accessible_accounts.visible.select(:id)).select(:security_id)
          watched = user.research_watchlist_entries.active.select(:security_id)
          Security.where(id: held).or(Security.where(id: watched)).pluck(:id).map(&:to_s)
        end
    end

    class << self
      def enum(key, default, values)
        Setting.new(key: key, type: "enum", default: default, values: values.freeze, minimum: nil, maximum: nil)
      end

      def integer(key, default, minimum, maximum)
        Setting.new(key: key, type: "integer", default: default, values: nil, minimum: minimum, maximum: maximum)
      end

      def identifier(key)
        Setting.new(key: key, type: "identifier", default: nil, values: nil, minimum: nil, maximum: nil)
      end

      def settings(scope: nil, period: false, rows: false, grouping: nil, sort: nil, filter: nil, density: false, display: nil)
        result = {}
        if scope
          result["scope"] = enum("scope", "overall", scope)
          result["account_id"] = identifier("account_id") if scope.include?("account")
          result["security_id"] = identifier("security_id") if scope.include?("security")
        end
        result["period"] = enum("period", "1y", %w[1m 3m ytd 1y]) if period
        result["rows"] = integer("rows", 5, 3, 12) if rows
        result["grouping"] = enum("grouping", grouping.first, grouping) if grouping
        result["sort"] = enum("sort", sort.first, sort) if sort
        result["filter"] = enum("filter", filter.first, filter) if filter
        result["density"] = enum("density", "compact", %w[compact detail]) if density
        result["display"] = enum("display", display.first, display) if display
        result.freeze
      end

      def definition(key, width: 6, height: 4, widths: [ 6, 12 ], heights: [ 4 ], investment: true, load_group:, settings: {})
        Definition.new(
          key: key,
          default_col_width: width,
          default_height: height,
          supported_col_widths: widths.freeze,
          supported_heights: heights.freeze,
          investment_required: investment,
          load_group: load_group,
          settings: settings
        )
      end
    end

    HOME_DEFINITIONS = [
      definition("home.ticker_news", width: 12, height: 3, heights: [ 3 ], investment: false, load_group: "home_news", settings: settings(scope: %w[overall security], rows: true)),
      definition("home.insights_feed", width: 12, height: 3, heights: [ 3 ], investment: false, load_group: "home_insights", settings: settings(rows: true)),
      definition("home.cashflow_sankey", width: 12, height: 6, heights: [ 6 ], investment: false, load_group: "home_cashflow"),
      definition("home.money_flow", investment: false, load_group: "home_cashflow"),
      definition("home.spending_trend", investment: false, load_group: "home_cashflow", heights: [ 3, 4, 6 ]),
      definition("home.outflows_donut", widths: [ 6 ], investment: false, load_group: "home_cashflow"),
      definition("home.investment_summary", investment: true, load_group: "home_investments"),
      definition("home.net_worth_chart", investment: false, load_group: "home_net_worth", heights: [ 3, 4, 6 ]),
      definition("home.balance_sheet", investment: false, load_group: "home_net_worth")
    ].freeze

    WORKSPACE_DEFINITIONS = [
      definition("investments.decision_center", width: 12, height: 5, heights: [ 5 ], load_group: "investment_decision"),
      definition("investments.holdings", height: 5, heights: [ 5 ], load_group: "investment_holdings", settings: settings(scope: %w[overall account], grouping: %w[security asset_class sector account])),
      definition("investments.income_performance", load_group: "investment_income", settings: settings(scope: %w[overall account], period: true)),
      definition("investments.tax_workspace", load_group: "investment_tax"),
      definition("investments.options", load_group: "investment_options", settings: settings(sort: %w[expiry underlying gain])),
      definition("investments.market_events", load_group: "investment_events", settings: settings(scope: %w[overall security], rows: true, filter: %w[all earnings dividends wash_sale])),
      definition("investments.watchlist", load_group: "investment_watchlist"),
      definition("investments.news", width: 12, height: 3, heights: [ 3 ], load_group: "home_news", settings: settings(scope: %w[overall security], rows: true, sort: %w[newest oldest]))
    ].freeze

    GRANULAR_DEFINITIONS = [
      definition("portfolio.pulse", load_group: "investment_decision"),
      definition("review.needs_review", load_group: "investment_decision", settings: settings(rows: true)),
      definition("review.source_health", load_group: "investment_decision", settings: settings(rows: true, filter: %w[all attention unavailable])),
      definition("portfolio.holdings_concentration", height: 5, heights: [ 4, 5 ], load_group: "portfolio_holdings", settings: settings(scope: %w[overall account], rows: true, sort: %w[market_value symbol])),
      definition("portfolio.allocation", load_group: "investment_holdings", settings: settings(scope: %w[overall account], rows: true, grouping: %w[asset_class sector security account])),
      definition("portfolio.top_holdings", load_group: "portfolio_holdings", settings: settings(scope: %w[overall account], rows: true, sort: %w[market_value symbol])),
      definition("review.data_quality", load_group: "investment_holdings", settings: settings(scope: %w[overall account], rows: true, filter: %w[all missing_basis stale_price])),
      definition("portfolio.security_snapshot", load_group: "security_snapshot", settings: settings(scope: %w[overall security])),
      definition("income.summary", load_group: "investment_income", settings: settings(scope: %w[overall account], period: true)),
      definition("income.monthly", load_group: "investment_income", settings: settings(scope: %w[overall account], period: true, rows: true)),
      definition("income.cash_flows", load_group: "investment_income", settings: settings(scope: %w[overall account], period: true)),
      definition("income.return_risk", load_group: "investment_income", settings: settings(scope: %w[overall account], period: true)),
      definition("income.options_premium", load_group: "investment_income", settings: settings(scope: %w[overall account], period: true)),
      definition("tax.realized_gains", load_group: "investment_tax"),
      definition("tax.lot_coverage", load_group: "investment_tax"),
      definition("tax.nearing_long_term", load_group: "investment_tax", settings: settings(rows: true)),
      definition("tax.harvest_summary", load_group: "investment_tax"),
      definition("tax.harvest_candidates", load_group: "investment_tax", settings: settings(rows: true)),
      definition("tax.wash_sale_exposure", load_group: "investment_tax", settings: settings(rows: true)),
      definition("options.summary", load_group: "investment_options"),
      definition("options.expiring", load_group: "investment_options", settings: settings(rows: true, sort: %w[expiry underlying], filter: %w[all expiring expired])),
      definition("options.premium_income", load_group: "investment_income", settings: settings(scope: %w[overall account], period: true)),
      definition("options.contract_ledger", load_group: "investment_options", settings: settings(rows: true, sort: %w[expiry underlying gain])),
      definition("options.underlying_concentration", load_group: "investment_options", settings: settings(rows: true, sort: %w[contracts gain])),
      definition("research.priority_watchlist", load_group: "investment_watchlist", settings: settings(rows: true, filter: %w[active priority ready])),
      definition("research.portfolio_news", width: 12, height: 3, heights: [ 3 ], load_group: "home_news", settings: settings(scope: %w[overall security], rows: true, sort: %w[newest oldest])),
      definition("research.upcoming_events", load_group: "investment_events", settings: settings(scope: %w[overall security], rows: true, filter: %w[all earnings dividends wash_sale])),
      definition("research.freshness", load_group: "research_freshness", settings: settings(rows: true))
    ].freeze

    DEFINITIONS = (HOME_DEFINITIONS + WORKSPACE_DEFINITIONS + GRANULAR_DEFINITIONS).freeze

    ALIASES = {
      "investments.decision_pulse" => "investments.decision_center",
      "investments.decision_action" => "investments.decision_center",
      "investments.decision_monitor" => "investments.decision_center",
      "investments.holdings_allocation" => "investments.holdings",
      "investments.holdings_data_quality" => "investments.holdings",
      "investments.income_cash_flows" => "investments.income_performance"
    }.freeze

    INDEX = DEFINITIONS.index_by(&:key).freeze

    class << self
      def all = DEFINITIONS
      def keys = INDEX.keys
      def canonical_key(key) = ALIASES.fetch(key.to_s, key.to_s)
      def fetch(key) = INDEX.fetch(canonical_key(key))
      def find(key) = INDEX[canonical_key(key)]
      def registered?(key) = find(key).present?
      def investment_keys = WORKSPACE_DEFINITIONS.map(&:key)
    end
  end
end
