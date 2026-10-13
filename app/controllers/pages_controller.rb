class PagesController < ApplicationController
  include Periodable

  # Number of consecutive months (ending at the selected month) shown as
  # bars in the "money_flow" dashboard widget.
  MONEY_FLOW_CHART_MONTHS = 6

  skip_authentication only: %i[redis_configuration_error privacy terms]
  before_action :ensure_intro_guest!, only: :intro

  # The homepage is a set of pages (Home, Investments, custom) the member
  # composes from registry widgets. Only the resolved page's widgets are
  # loaded and rendered; data is loaded once per registry load group so two
  # widgets sharing a source share its queries.
  def dashboard
    if Current.user&.ui_layout_intro?
      redirect_to chats_path and return
    end

    if legacy_decision_view_requested?
      @decision_center = InvestmentDecisionCenter.new(user: Current.user)
      if @decision_center.available?
        @dashboard_view = "decision"
        @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("investment_decision_center.breadcrumb"), nil ] ]
        render :decision_center and return
      end
    end

    @dashboard_pages = Current.user.dashboard_pages
    @dashboard_view = resolve_dashboard_view
    @accounts = Current.user.accessible_accounts.visible.with_attached_logo
    @dashboard_sections = build_dashboard_page_sections(@dashboard_page)
    @dashboard_tabs = @dashboard_pages.map do |page|
      { key: page.fetch("id"), title: page.fetch("name"), path: root_path(page: page.fetch("id")) }
    end
    @dashboard_add_widget = dashboard_add_widget_options(@dashboard_page)
    @dashboard_page_management = dashboard_page_management_options

    @breadcrumbs = if @dashboard_page_id == "investments"
      [ [ t("breadcrumbs.home"), root_path ], [ t("investment_decision_center.breadcrumb"), nil ] ]
    else
      [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.dashboard"), nil ] ]
    end
  end

  def intro
    @breadcrumbs = [ [ t("breadcrumbs.home"), chats_path ], [ t("breadcrumbs.intro"), nil ] ]
  end

  def update_preferences
    if Current.user.update_dashboard_preferences(preferences_params)
      head :ok
    else
      head :unprocessable_entity
    end
  end

  def changelog
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.changelog"), nil ] ]
    @release_notes = github_provider.fetch_latest_release_notes

    # Fallback if no release notes are available
    if @release_notes.nil?
      @release_notes = {
        avatar: "https://github.com/we-promise.png",
        username: "we-promise",
        name: t("pages.release_notes_unavailable.name"),
        published_at: Date.current,
        body: t("pages.release_notes_unavailable.body_html")
      }
    end

    render layout: "settings"
  end

  def feedback
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.feedback"), nil ] ]
    render layout: "settings"
  end

  def redis_configuration_error
    render layout: "blank"
  end

  def privacy
    render layout: "blank"
  end

  def terms
    render layout: "blank"
  end

  private
    def legacy_decision_view_requested?
      return false if params[:page].present?
      return true if params[:view].to_s == "decision"

      params[:view].blank? && Current.user.preferences&.[]("dashboard_current_page").blank? && Current.user.dashboard_view == "decision"
    end

    # Resolve the new page id first, with legacy view aliases kept read-forward.
    # GET requests never change preferences. Unknown, deleted, or currently
    # inaccessible pages fall back to Home without persisting that fallback.
    def resolve_dashboard_view
      pages = @dashboard_pages
      requested_page = params[:page].presence

      if requested_page
        candidate = User::DASHBOARD_PAGE_ALIASES.fetch(requested_page.to_s, requested_page.to_s)
        page = pages.find { |item| item["id"] == candidate }
        page ||= pages.find { |item| item["id"] == "home" }
      else
        requested_view = params[:view].to_s
        if User::DASHBOARD_PAGE_ALIASES.key?(requested_view)
          candidate = User::DASHBOARD_PAGE_ALIASES.fetch(requested_view)
        else
          candidate = Current.user.dashboard_current_page
        end
        page = pages.find { |item| item["id"] == candidate } || pages.find { |item| item["id"] == "home" }
      end

      @dashboard_page = page
      @dashboard_page_id = page.fetch("id")
      # The Investments page only exists in `pages` for members with investment
      # access, so its presence is the access check; the legacy "decision" lens
      # name keeps the main navigation's Home/Investments highlighting intact.
      @dashboard_page_id == "investments" ? "decision" : "overview"
    end


    def preferences_params
      prefs = params.require(:preferences)
      {}.tap do |permitted|
        permitted["collapsed_sections"] = prefs[:collapsed_sections].to_unsafe_h if prefs[:collapsed_sections].respond_to?(:to_unsafe_h)
        permitted["section_order"] = prefs[:section_order] if prefs[:section_order].is_a?(Array)
        permitted["dashboard_section_layout"] = prefs[:dashboard_section_layout].to_unsafe_h if prefs[:dashboard_section_layout].respond_to?(:to_unsafe_h)
      end
    end

    # One card description per widget on the page, in the page's saved order.
    # Widgets that cannot be rendered for this member (a preview feature that
    # is off, an investment source that is unavailable) carry an honest
    # `unavailable` state instead of being dropped, so the card can still be
    # seen and removed; the one exception is a preview-gated widget, which is
    # hidden entirely because the feature itself is not offered.
    def build_dashboard_page_sections(page)
      sections = page.fetch("widgets").filter_map do |widget|
        definition = Dashboard::WidgetRegistry.fetch(widget["key"])
        entry = Dashboard::WidgetCatalog.fetch(definition.key)
        next if entry.key == "home.insights_feed" && !preview_features_enabled?

        settings = widget.fetch("settings")
        content = dashboard_widget_content(entry, settings)
        layout = dashboard_widget_layout(definition, widget.fetch("layout"))
        instance_id = widget.fetch("id")

        {
          instance_id: instance_id,
          key: definition.key,
          legacy_key: entry.legacy_key,
          dom_id: "dashboard-widget-#{instance_id}",
          title: entry.title_key,
          partial: entry.partial,
          padded: entry.padded,
          collapsed: widget["collapsed"] == true,
          layout: layout,
          settings: dashboard_widget_settings(definition, settings),
          raw_settings: settings,
          setting_summary: dashboard_widget_setting_summary(definition, settings),
          scope_label: dashboard_widget_scope_label(settings),
          locals: dashboard_widget_locals(entry, content.fetch(:locals, {}), instance_id, layout),
          unavailable: content[:unavailable],
          workspace_url: dashboard_widget_workspace_path(entry, settings),
          duplicate_url: page_widgets_path(page.fetch("id")),
          update_url: page_widget_path(page.fetch("id"), instance_id),
          remove_url: page_widget_path(page.fetch("id"), instance_id)
        }
      end

      legacy_order = Array(Current.user.preferences&.[]("section_order"))
      if page.fetch("id") == "home" && Current.user.preferences&.[]("dashboard_pages").nil? &&
          !legacy_order.include?("insights_feed")
        insights = sections.find { |section| section[:key] == "home.insights_feed" }
        sections.unshift(sections.delete(insights)) if insights
      end
      sections
    end

    # Width/height the member saved for this instance of the widget, plus what
    # the registry allows it to change to. A widget whose definition offers a
    # single width and a single height gets no size menu at all.
    def dashboard_widget_layout(definition, saved)
      col_width = saved.fetch("col_width")
      height = saved.fetch("height")
      grow = definition.supported_heights.size > 1

      {
        col_width: col_width,
        height: height,
        col_span: col_width == 12 ? "full" : "single",
        grow: grow,
        height_px: Dashboard::WidgetCatalog.height_px(height),
        height_preset: Dashboard::WidgetCatalog.height_preset(height),
        width_options: definition.supported_col_widths.size > 1 ? definition.supported_col_widths : [],
        height_options: grow ? definition.supported_heights : []
      }
    end

    def dashboard_widget_locals(entry, locals, instance_id, layout)
      result = locals.dup
      result[:col_span] = layout.fetch(:col_span) if entry.key == "home.money_flow"

      prefix = "widget-#{instance_id}"
      if entry.key.start_with?("home.") || entry.key == "research.news"
        result[:widget_id] = prefix
      end
      result[:chart_id] = "#{prefix}-chart" if entry.key == "home.net_worth_chart"
      result[:dialog_id] = "#{prefix}-dialog" if entry.key == "home.cashflow_sankey"
      result
    end

    def dashboard_widget_settings(definition, values)
      definition.settings.values.map do |setting|
        options = case setting.key
        when "account_id"
          dashboard_scope_accounts.order(:name).pluck(:name, :id).map { |name, id| [ name, id.to_s ] }
        when "security_id"
          dashboard_accessible_securities.map { |security| [ "#{security.ticker} · #{security.name}", security.id.to_s ] }
        else
          Array(setting.values).map { |value| [ helpers.dashboard_setting_option_label(setting.key, value), value ] }
        end
        { key: setting.key, type: setting.type, value: values[setting.key], default: setting.default, options: options, minimum: setting.minimum, maximum: setting.maximum }
      end
    end

    def dashboard_widget_setting_summary(definition, values)
      definition.settings.values.filter_map do |setting|
        next if %w[scope account_id security_id].include?(setting.key)

        value = values[setting.key]
        next if value.nil?

        label = t("pages.dashboard.settings.labels.#{setting.key}")
        display = setting.type == "integer" ? value.to_s : helpers.dashboard_setting_option_label(setting.key, value)
        t("pages.dashboard.settings.summary", label: label, value: display)
      end
    end

    def dashboard_widget_scope_label(settings)
      case settings["scope"]
      when "account"
        Current.user.accessible_accounts.visible.find_by(id: settings["account_id"])&.name || t("pages.dashboard.settings.unavailable_scope")
      when "security"
        dashboard_accessible_securities.find { |security| security.id.to_s == settings["security_id"] }&.ticker || t("pages.dashboard.settings.unavailable_scope")
      when "overall", "portfolio", "watchlist"
        t("pages.dashboard.settings.options.scope.#{settings["scope"]}")
      end
    end

    def dashboard_accessible_securities
      @dashboard_accessible_securities ||= begin
        held = Holding.where(account_id: Current.user.accessible_accounts.visible.select(:id)).select(:security_id)
        watched = Current.user.research_watchlist_entries.active.select(:security_id)
        Security.where(id: held).or(Security.where(id: watched)).order(:ticker).to_a
      end
    end

    def dashboard_scope_accounts
      Current.user.accessible_accounts.visible.where(accountable_type: %w[Investment Crypto])
    end

    # Locals for the widget's partial, or an unavailable state when the data
    # behind it cannot be supplied. Everything is scoped to Current.user and
    # loaded at most once per registry load group.
    def dashboard_widget_content(entry, settings)
      case entry.key
      when "research.news"
        articles = scoped_news(load_group(:research_news), settings)
        if articles.nil?
          unavailable_widget(entry, "scope_unavailable", settings)
        else
          articles = articles.first(settings.fetch("rows"))
          articles.any? ? { locals: { articles: articles, news_settings: settings, news_url: dashboard_widget_workspace_path(entry, settings) } } : unavailable_widget(entry, "no_news", settings)
        end
      when "home.insights_feed"
        insights = load_group(:home_insights).first(settings.fetch("rows", Insight::FEED_LIMIT))
        insights.any? ? { locals: { insights: insights } } : unavailable_widget(entry, "no_insights")
      when "home.cashflow_sankey"
        { locals: { sankey_data: load_group(:home_cashflow).fetch(:sankey), period: @period } }
      when "home.money_flow"
        cashflow = load_group(:home_cashflow)
        { locals: { money_flow_data: cashflow.fetch(:money_flow), accounts: cashflow.fetch(:money_flow_accounts), accessible_account_ids: cashflow.fetch(:accessible_account_ids) } }
      when "home.spending_trend"
        { locals: { spending_trend_data: load_group(:home_cashflow).fetch(:spending_trend) } }
      when "home.outflows_donut"
        outflows = load_group(:home_cashflow).fetch(:outflows)
        outflows[:categories].present? ? { locals: { outflows_data: outflows, period: @period } } : unavailable_widget(entry, "no_outflows")
      when "home.investment_summary"
        statement = load_group(:home_investments)
        statement.investment_accounts.any? ? { locals: { investment_statement: statement, period: @period } } : unavailable_widget(entry, "no_investments")
      when "home.net_worth_chart"
        { locals: { balance_sheet: load_group(:home_net_worth), period: @period } }
      when "home.balance_sheet"
        { locals: { balance_sheet: load_group(:home_net_worth) } }
      when "investments.decision_center"
        center = load_group(:investment_decision)
        center.available? ? { locals: { center: center } } : unavailable_widget(entry, "no_investments")
      when "investments.holdings"
        allocation = load_group(:investment_holdings, settings)
        allocation ? { locals: { allocation: allocation, currency: allocation.currency } } : unavailable_widget(entry, "failed")
      when "investments.income_performance"
        review = load_group(:investment_income, settings)
        if review.nil?
          unavailable_widget(entry, "failed")
        elsif review.accounts.none?
          unavailable_widget(entry, "no_investments")
        else
          { locals: { review: review, currency: review.currency } }
        end
      when "investments.tax_workspace"
        data = load_group(:investment_tax)
        data ? { locals: data } : unavailable_widget(entry, "failed")
      when "investments.options"
        review = load_group(:investment_options, settings)
        review ? { locals: { review: review } } : unavailable_widget(entry, "failed")
      when "investments.market_events"
        events = scoped_events(load_group(:investment_events), settings)
        events ? { locals: events } : unavailable_widget(entry, "failed")
      when "investments.watchlist"
        watchlist = load_group(:investment_watchlist)
        watchlist ? { locals: watchlist } : unavailable_widget(entry, "failed")
      else
        dashboard_granular_widget_content(entry, settings)
      end
    end

    def dashboard_granular_widget_content(entry, settings)
      rows = settings.fetch("rows", 5)
      data = case entry.key
      when "portfolio.pulse"
        center = load_group(:investment_decision)
        pulse = center.pulse
        {
          metrics: [
            dashboard_metric("portfolio_value", pulse&.portfolio_value ? helpers.format_money(pulse.portfolio_value) : nil),
            dashboard_metric("cash", pulse&.cash_balance ? helpers.format_money(pulse.cash_balance) : nil),
            dashboard_metric("as_of", pulse&.as_of ? helpers.l(pulse.as_of, format: :long) : nil)
          ]
        }
      when "review.needs_review"
        actions = load_group(:investment_decision).actions
        { metrics: [ dashboard_metric("needs_review", actions&.sum(&:count)) ], rows: Array(actions).first(rows).map { |action| { primary: t("pages.dashboard.granular_data.action_#{action.kind}"), secondary: action.count.to_s } } }
      when "review.source_health"
        health = Array(load_group(:investment_decision).source_health)
        health = health.select { |item| item.status != "current" } if settings["filter"].in?(%w[attention unavailable])
        health = health.select { |item| item.status == "unavailable" } if settings["filter"] == "unavailable"
        { rows: health.first(rows).map { |item| { primary: item.label, secondary: item.status.humanize, detail: item.detail, tone: item.status == "current" ? nil : "text-warning" } } }
      when "portfolio.top_holdings"
        dashboard_portfolio_positions_widget_data(entry.key, settings, rows)
      when "portfolio.day_movers", "portfolio.largest_position", "portfolio.account_balances", "portfolio.cash_liquidity", "portfolio.holdings_count"
        dashboard_portfolio_positions_widget_data(entry.key, settings, rows)
      when "portfolio.allocation"
        allocation = load_group(:investment_holdings, settings)
        { metrics: [ dashboard_allocation_lead_metric(allocation), dashboard_metric("unavailable", allocation.excluded_count) ], rows: allocation.display_segments(limit: rows).map { |segment| { primary: segment.label, secondary: segment.weight ? helpers.number_to_percentage(segment.weight, precision: 1) : nil, progress: segment.weight } } }
      when "review.data_quality"
        allocation = load_group(:investment_holdings, settings)
        issues = allocation.data_quality
        issues = issues.select { |issue| issue.kind.to_s == settings["filter"] } unless settings["filter"] == "all"
        { metrics: [ dashboard_metric("data_issues", issues.size) ], rows: issues.first(rows).map { |issue| { primary: issue.security.ticker, secondary: t("pages.dashboard.granular_data.#{issue.kind}"), detail: issue.detail&.to_s, tone: "text-warning" } } }
      when "portfolio.security_snapshot"
        security = dashboard_accessible_securities.find { |candidate| candidate.id.to_s == settings["security_id"] }
        if security
          holding = Holding::CurrentForInvestmentAccounts.new(Current.user.accessible_accounts.visible.select(:id)).relation.where(security_id: security.id).order(date: :desc).first
          { metrics: [ dashboard_metric("price", holding&.price ? helpers.investment_money(holding.price, holding.currency) : nil), dashboard_metric("market_value", holding&.amount_money ? helpers.format_money(holding.amount_money) : nil), dashboard_metric("quantity", holding&.qty&.to_s) ] }
        else
          { metrics: [ dashboard_metric("securities", dashboard_accessible_securities.size) ] }
        end
      when "income.summary", "income.cash_flows", "income.return_risk", "options.premium_income", "income.monthly", "income.by_type", "income.top_months", "income.fx_gaps"
        dashboard_income_widget_data(entry.key, settings, rows)
      when "tax.realized_gains", "tax.lot_coverage", "tax.harvest_summary", "tax.harvest_candidates", "tax.wash_sale_exposure", "tax.term_split", "tax.unrealized_by_holding", "tax.harvest_loss_total", "tax.fx_unavailable", "tax.long_term_window"
        dashboard_tax_widget_data(entry.key, settings, rows)
      when "options.summary", "options.contract_ledger", "options.expiration_window", "options.dte_distribution", "options.by_underlying", "options.unmeasured"
        dashboard_options_widget_data(entry.key, settings, rows)
      when "research.watchlist_snapshot"
        scope = Current.user.research_watchlist_entries.active.includes(:security).order(:priority, :created_at)
        scope = scope.where(priority: 1..2) if settings["filter"] == "priority"
        scope = scope.where(status: "ready") if settings["filter"] == "ready"
        items = scope.limit(rows).to_a
        if settings["display"] == "price"
          holdings = Holding::CurrentForInvestmentAccounts.new(Current.user.accessible_accounts.visible.select(:id)).relation
            .where(security_id: items.map(&:security_id)).order(date: :desc).group_by(&:security_id).transform_values(&:first)
          { metrics: [ dashboard_metric("watchlist_total", scope.count) ], rows: items.map { |item| { primary: item.security.ticker, secondary: helpers.investment_money(holdings[item.security_id]&.price, holdings[item.security_id]&.currency), detail: item.status.humanize } } }
        else
          { metrics: [ dashboard_metric("watchlist_total", scope.count) ], rows: items.map { |item| { primary: item.security.ticker, secondary: item.status.humanize, detail: item.thesis } } }
        end
      when "research.event_countdown"
        events = scoped_events(load_group(:investment_events), settings).fetch(:events).first(rows)
        { rows: events.map { |event| { primary: "#{event.ticker} · #{event.title}", secondary: helpers.l(event.date, format: :short) } } }
      when "research.freshness"
        snapshots = SecurityResearchSnapshot.includes(:security).where(security_id: dashboard_accessible_securities.map(&:id)).order(updated_at: :desc).limit(rows)
        { rows: snapshots.map { |snapshot| { primary: snapshot.security.ticker, secondary: helpers.l(snapshot.updated_at, format: :short) } } }
      end

      data ? { locals: { widget_data: data } } : unavailable_widget(entry, "failed")
    rescue StandardError => e
      Rails.logger.warn("[dashboard] granular widget #{entry.key} unavailable: #{e.class}: #{e.message}")
      unavailable_widget(entry, "failed")
    end

    def dashboard_portfolio_positions_widget_data(key, settings, rows)
      portfolio = load_group(:portfolio_holdings, settings)
      blocks = portfolio.blocks
      positions = blocks.flat_map(&:positions)
      converted = dashboard_positions_in_currency(positions, Current.family.currency)

      case key
      when "portfolio.day_movers"
        measured = positions.select { |position| !position.day_gain.nil? }
        ordered = measured.sort_by { |position| [ position.day_gain, position.ticker ] }
        ordered.reverse! if settings["sort"] == "gainers"
        {
          metrics: [ dashboard_metric("measured_positions", measured.size), dashboard_metric("unavailable", positions.size - measured.size) ],
          rows: ordered.first(rows).map { |position| { primary: position.ticker, secondary: helpers.investment_gain(position.day_gain, position.currency, percent: position.day_gain_pct), detail: position.account.name } }
        }
      when "portfolio.largest_position"
        largest = converted&.max_by(&:last)
        total = converted&.sum(BigDecimal("0")) { |_position, value| value }
        weight = largest && total&.positive? ? largest.last / total * 100 : nil
        {
          metrics: [ dashboard_metric("largest_weight", weight ? helpers.number_to_percentage(weight, precision: 1) : nil) ],
          rows: largest ? [ { primary: largest.first.ticker, secondary: helpers.investment_money(largest.last, Current.family.currency), detail: largest.first.account.name, progress: weight } ] : []
        }
      when "portfolio.account_balances"
        ordered_blocks = settings["sort"] == "symbol" ? blocks.sort_by { |block| block.account.name.downcase } : blocks.sort_by { |block| -block.market_value.to_d }
        {
          metrics: [ dashboard_metric("accounts", blocks.size) ],
          rows: ordered_blocks.first(rows).map { |block| { primary: block.account.name, secondary: helpers.investment_money(block.market_value, block.currency), detail: block.currency } }
        }
      when "portfolio.cash_liquidity"
        ordered_blocks = settings["sort"] == "symbol" ? blocks.sort_by { |block| block.account.name.downcase } : blocks.sort_by { |block| -block.cash.to_d }
        cash_rows = ordered_blocks.map { |block| { primary: block.account.name, secondary: helpers.investment_money(block.cash, block.currency), detail: block.currency } }
        sweeps = positions.select { |position| position.security.cash? || position.security.name.to_s.match?(TaxLotReview::CASH_SWEEP_NAME) }
        uncertain = positions.select { |position| position.price == 1 && !sweeps.include?(position) }
        sweep_rows = sweeps.map { |position| { primary: position.ticker, secondary: helpers.investment_money(position.market_value, position.currency), detail: position.account.name } }
        { metrics: [ dashboard_metric("cash_accounts", cash_rows.size), dashboard_metric("money_market_positions", sweeps.size), dashboard_metric("unavailable", uncertain.size) ], rows: (cash_rows + sweep_rows).first(rows) }
      when "portfolio.holdings_count"
        { metrics: [ dashboard_metric("holdings", positions.size), dashboard_metric("accounts", blocks.size), dashboard_metric("securities", positions.map { |position| position.security.id }.uniq.size) ] }
      else
        ordered = if settings["sort"] == "symbol" || converted.nil?
          positions.sort_by(&:ticker)
        else
          converted.sort_by { |_position, value| -value }.map(&:first)
        end
        total = converted&.sum(BigDecimal("0")) { |_position, value| value }
        { metrics: [ dashboard_metric("top_share", dashboard_top_share(converted, ordered, total, rows)) ], rows: ordered.first(rows).map { |position| { primary: position.ticker, secondary: helpers.investment_money(position.market_value, position.currency), detail: position.account.name } } }
      end
    end

    def dashboard_income_widget_data(key, settings, rows)
      review = load_group(:investment_income, settings)
      return unless review

      case key
      when "income.summary"
        { metrics: [ dashboard_metric("income", helpers.investment_money(review.income_total, review.currency)), dashboard_metric("net_contributions", helpers.investment_money(review.net_contributions, review.currency)) ] }
      when "income.cash_flows"
        { metrics: [ dashboard_metric("contributions", helpers.investment_money(review.total(:contributions), review.currency)), dashboard_metric("withdrawals", helpers.investment_money(review.total(:withdrawals), review.currency)), dashboard_metric("net_contributions", helpers.investment_money(review.net_contributions, review.currency)) ] }
      when "income.return_risk"
        performance = review.money_weighted_return
        risk = review.risk_metrics
        { metrics: [ dashboard_metric("money_weighted_return", performance ? helpers.number_to_percentage(performance.rate * 100, precision: 1) : nil), dashboard_metric("volatility", risk ? helpers.number_to_percentage(risk.volatility * 100, precision: 1) : nil), dashboard_metric("max_drawdown", risk ? helpers.number_to_percentage(risk.max_drawdown * 100, precision: 1) : nil) ] }
      when "options.premium_income"
        premium = review.option_premium
        { metrics: [ dashboard_metric("net_premium", helpers.investment_money(premium[:net], review.currency)), dashboard_metric("contracts", premium[:count]), dashboard_metric("unavailable", premium[:unconverted]) ] }
      when "income.monthly"
        monthly = review.monthly_income.last(rows).reverse
        { rows: monthly.map { |item| { primary: helpers.l(item.month, format: :month_year), secondary: helpers.investment_money(item.total, review.currency) } } }
      when "income.by_type"
        { metrics: [ dashboard_metric("dividends", helpers.investment_money(review.total(:dividends), review.currency)), dashboard_metric("interest", helpers.investment_money(review.total(:interest), review.currency)) ] }
      when "income.top_months"
        monthly = review.monthly_income.select { |item| !item.total.nil? }.sort_by { |item| -item.total }.first(rows)
        { rows: monthly.map { |item| { primary: helpers.l(item.month, format: :month_year), secondary: helpers.investment_money(item.total, review.currency) } } }
      when "income.fx_gaps"
        { metrics: [ dashboard_metric("missing_fx", review.missing_fx_count) ] }
      end
    end

    def dashboard_tax_widget_data(key, settings, rows)
      data = load_group(:investment_tax)
      return unless data

      review = data.fetch(:review)
      harvest = data.fetch(:harvest)
      case key
      when "tax.realized_gains"
        realized = harvest.realized_year_to_date
        { metrics: [ dashboard_metric("realized_gain_loss", realized[:amount] ? helpers.format_money(realized[:amount]) : nil), dashboard_metric("measured_sales", realized[:known]), dashboard_metric("unavailable", realized[:unknown]) ] }
      when "tax.lot_coverage"
        { metrics: [ dashboard_metric("measured_lots", review.lots.size), dashboard_metric("lot_gaps", review.positions_without_lots + review.unmeasured_count) ] }
      when "tax.harvest_summary"
        { metrics: [ dashboard_metric("harvest_candidates", harvest.candidates.size), dashboard_metric("measured_loss", helpers.format_money(harvest.totals.loss)), dashboard_metric("unavailable", harvest.unavailable.size) ] }
      when "tax.harvest_candidates"
        { rows: harvest.candidates.first(rows).map { |candidate| { primary: candidate.ticker, secondary: helpers.format_money(candidate.loss.abs), detail: candidate.account.name, tone: "text-warning" } } }
      when "tax.wash_sale_exposure"
        candidates = harvest.rows.select { |candidate| candidate.wash_flags.any? }
        { metrics: [ dashboard_metric("wash_sale_exposure", candidates.size) ], rows: candidates.first(rows).map { |candidate| { primary: candidate.ticker, secondary: candidate.wash_flags.map { |flag| flag.kind.to_s.humanize }.uniq.join(" · "), detail: candidate.account.name, tone: "text-warning" } } }
      when "tax.term_split"
        totals = review.totals
        complete = review.positions_without_lots.zero? && review.unmeasured_count.zero?
        { metrics: [ dashboard_metric("short_term_gain", complete ? helpers.investment_money(totals[:short_gain], review.currency) : nil), dashboard_metric("short_term_loss", complete ? helpers.investment_money(totals[:short_loss], review.currency) : nil), dashboard_metric("long_term_gain", complete ? helpers.investment_money(totals[:long_gain], review.currency) : nil), dashboard_metric("long_term_loss", complete ? helpers.investment_money(totals[:long_loss], review.currency) : nil) ] }
      when "tax.unrealized_by_holding"
        grouped = review.lots.group_by(&:ticker).map do |ticker, lots|
          { ticker: ticker, gain: lots.sum(BigDecimal("0"), &:gain), account: lots.map { |lot| lot.account.name }.uniq.join(" · ") }
        end
        grouped.sort_by! { |item| settings["sort"] == "ticker" ? item[:ticker] : (settings["sort"] == "loss" ? item[:gain] : -item[:gain]) }
        { rows: grouped.first(rows).map { |item| { primary: item[:ticker], secondary: helpers.investment_gain(item[:gain], review.currency), detail: item[:account] } } }
      when "tax.harvest_loss_total"
        { metrics: [ dashboard_metric("measured_loss", helpers.format_money(harvest.totals.loss)), dashboard_metric("harvest_candidates", harvest.candidates.size), dashboard_metric("unavailable", harvest.unavailable.size) ] }
      when "tax.fx_unavailable"
        unavailable = harvest.unavailable.select { |item| item.reason == :exchange_rate_missing }
        { metrics: [ dashboard_metric("missing_fx", unavailable.size) ], rows: unavailable.first(rows).map { |item| { primary: item.ticker, secondary: t("pages.dashboard.granular_data.exchange_rate_missing"), detail: item.account.name, tone: "text-warning" } } }
      when "tax.long_term_window"
        window = settings.fetch("window").to_i
        lots = review.lots.select { |lot| lot.term == :short && lot.days_to_long_term <= window }.sort_by { |lot| [ lot.days_to_long_term, lot.ticker ] }
        { metrics: [ dashboard_metric("approaching_long_term", lots.size) ], rows: lots.first(rows).map { |lot| { primary: lot.ticker, secondary: t("pages.dashboard.granular_data.days", count: lot.days_to_long_term), detail: lot.account.name } } }
      end
    end

    def dashboard_options_widget_data(key, settings, rows)
      review = load_group(:investment_options, settings)
      return unless review

      case key
      when "options.summary"
        { metrics: [ dashboard_metric("contracts", review.rows.size), dashboard_metric("expiring", review.expiring_soon_count), dashboard_metric("expired", review.expired_count), dashboard_metric("gain_loss", helpers.investment_money(review.total_gain, review.currency)) ] }
      when "options.contract_ledger"
        { rows: review.rows.first(rows).map { |row| { primary: row.position.contract, secondary: helpers.investment_money(row.position.gain, row.position.currency), detail: row.account.name } } }
      when "options.by_underlying"
        groups = review.groups.sort_by { |group| settings["sort"] == "gain" ? -(group.gain || 0) : -group.rows.size }
        { rows: groups.first(rows).map { |group| { primary: group.underlying, secondary: t("pages.dashboard.granular_data.contract_count", count: group.rows.size), detail: helpers.investment_money(group.gain, group.currency) } } }
      when "options.expiration_window"
        window = settings.fetch("window").to_i
        selected = review.rows.select do |row|
          days = row.position.days_to_expiry(Date.current)
          next false unless days

          case settings["filter"]
          when "expired" then days.negative?
          when "expiring" then days.between?(0, window)
          else days <= window
          end
        end
        selected.sort_by! { |row| settings["sort"] == "underlying" ? [ row.position.underlying.to_s, row.position.expiration || Date.new(9999, 1, 1) ] : [ row.position.expiration || Date.new(9999, 1, 1), row.position.underlying.to_s ] }
        { metrics: [ dashboard_metric(settings["filter"] == "expired" ? "expired" : "expiring", selected.size) ], rows: selected.first(rows).map { |row| { primary: row.position.contract, secondary: row.position.expiration ? helpers.l(row.position.expiration, format: :long) : nil, detail: row.account.name } } }
      when "options.dte_distribution"
        days = review.rows.filter_map { |row| row.position.days_to_expiry(Date.current) }
        { metrics: [ dashboard_metric("dte_0_7", days.count { |value| value.between?(0, 7) }), dashboard_metric("dte_8_30", days.count { |value| value.between?(8, 30) }), dashboard_metric("dte_over_30", days.count { |value| value > 30 }), dashboard_metric("expired", days.count(&:negative?)) ] }
      when "options.unmeasured"
        selected = review.rows.select { |row| row.position.gain.nil? || row.position.expiration.nil? }
        { metrics: [ dashboard_metric("unavailable", selected.size) ], rows: selected.first(rows).map { |row| { primary: row.position.contract, secondary: helpers.unavailable_cell, detail: row.account.name } } }
      end
    end

    # Portfolio value belongs to the one canonical Portfolio pulse widget. Other
    # portfolio widgets lead with the figure that is specific to them, so the same
    # total is not repeated across a page.
    def dashboard_allocation_lead_metric(allocation)
      largest = allocation.segments.reject { |segment| InvestmentAllocation::FIXED_LABELS.include?(segment.label) }.first
      return dashboard_metric("largest_segment", nil) unless largest&.weight

      { label: t("pages.dashboard.granular_data.largest_segment"), value: helpers.number_to_percentage(largest.weight, precision: 1), hint: largest.label }
    end

    def dashboard_top_share(converted, ordered, total, rows)
      return nil if converted.nil? || total.nil? || !total.positive?

      values = converted.to_h { |position, value| [ position, value ] }
      top = ordered.first(rows).sum(BigDecimal("0")) { |position| values.fetch(position) }
      helpers.number_to_percentage(top / total * 100, precision: 1)
    end

    def dashboard_metric(key, value)
      { label: t("pages.dashboard.granular_data.#{key}"), value: value.presence || helpers.unavailable_cell }
    end

    def dashboard_positions_in_currency(positions, currency)
      return nil if positions.any? { |position| position.market_value.nil? || position.currency.blank? }

      foreign_currencies = positions.map(&:currency).uniq.reject { |source| source == currency }
      rates = ExchangeRate.rates_for(foreign_currencies, to: currency, date: Date.current, fallback: nil)
      positions.map do |position|
        value = position.market_value.to_d
        if position.currency != currency
          rate = rates[position.currency]
          return nil unless ExchangeRate.valid_rate?(rate)

          value *= rate
        end
        [ position, value ]
      end
    rescue ArgumentError, TypeError
      nil
    end

    def scoped_news(articles, settings)
      scoped = articles
      security_ids = case settings["scope"]
      when "portfolio"
        Holding.where(account_id: Current.user.accessible_accounts.visible.select(:id)).distinct.pluck(:security_id).map(&:to_s)
      when "account"
        account = dashboard_scope_accounts.find_by(id: settings["account_id"])
        return unless account

        Holding.where(account_id: account.id).distinct.pluck(:security_id).map(&:to_s)
      when "security"
        security = dashboard_accessible_securities.find { |candidate| candidate.id.to_s == settings["security_id"] }
        return unless security

        [ security.id.to_s ]
      when "watchlist"
        Current.user.research_watchlist_entries.active.pluck(:security_id).map(&:to_s)
      end
      scoped = scoped.select { |article| security_ids.include?(article[:security_id]) } if security_ids

      unless settings["period"] == "all"
        period = dashboard_setting_period(settings)
        scoped = scoped.select do |article|
          published_at = dashboard_news_published_at(article[:published_at])
          published_at && published_at.to_date.between?(period.start_date, period.end_date)
        end
      end

      if settings["filter"] == "sentiment"
        scoped = scoped.select { |article| Array(article[:headline_sentiments]).any? }
      end
      if settings["sentiment"].present? && settings["sentiment"] != "all"
        scoped = scoped.select { |article| Array(article[:headline_sentiments]).any? { |sentiment| sentiment[:tone] == settings["sentiment"] } }
      end

      case settings["sort"]
      when "oldest" then scoped.sort_by { |article| dashboard_news_published_at(article[:published_at]) || Time.zone.at(0) }
      when "title" then scoped.sort_by { |article| article[:title].downcase }
      else scoped.sort_by { |article| dashboard_news_published_at(article[:published_at]) || Time.zone.at(0) }.reverse
      end
    end

    def dashboard_news_published_at(value)
      return value.in_time_zone if value.respond_to?(:in_time_zone)

      Time.zone.parse(value.to_s) if value.present?
    rescue ArgumentError, TypeError
      nil
    end

    def scoped_events(data, settings)
      result = data.deep_dup
      events = result.fetch(:events)
      if settings["scope"] == "security"
        ticker = dashboard_accessible_securities.find { |security| security.id.to_s == settings["security_id"] }&.ticker
        events = events.select { |event| event.ticker == ticker }
      end
      filter = settings["filter"]
      events = events.select { |event| event.event_type == { "earnings" => "earnings", "dividends" => "ex_dividend", "wash_sale" => "wash_sale" }[filter] } unless filter.nil? || filter == "all"
      result[:events] = events.first(settings.fetch("rows", 5))
      result
    end

    def dashboard_widget_workspace_path(entry, settings = {})
      allowed = case entry.canonical_route
      when :portfolio_holdings then %w[account sort dir by]
      when :investment_income then %w[period]
      when :tax_lot_review then %w[tab ticker term sort dir]
      when :options_review then %w[sort dir]
      when :market_events then %w[from to type]
      when :research_watchlist_entries then %w[status]
      when :research_news then %w[scope account_id period filter density q source category sentiment ticker sort page]
      else []
      end
      query = request.query_parameters.slice(*allowed)
      if entry.canonical_route == :research_news && settings.present?
        query["scope"] = settings["scope"]
        query["account_id"] = settings["account_id"] if settings["scope"] == "account"
        if settings["scope"] == "security"
          query["ticker"] = dashboard_accessible_securities.find { |security| security.id.to_s == settings["security_id"] }&.ticker
        end
        query["period"] = settings["period"]
        query["filter"] = settings["filter"]
        query["density"] = settings["density"]
        query["sentiment"] = settings["sentiment"] unless settings["sentiment"].in?([ nil, "all" ])
        query["sort"] = { "newest" => "latest", "oldest" => "oldest", "title" => "title" }.fetch(settings["sort"], "latest")
      end

      return root_path(query.merge(page: nil, view: "decision")) if entry.canonical_route == :investment_decision
      return unless entry.canonical_route

      public_send("#{entry.canonical_route}_path", query)
    end

    def unavailable_widget(entry, reason, settings = {})
      {
        unavailable: {
          message: t("pages.dashboard.widget_unavailable.#{reason}"),
          href: dashboard_widget_workspace_path(entry, settings),
          link_text: entry.canonical_route ? t("pages.dashboard.widget_unavailable.open_#{entry.canonical_route}", default: t("pages.dashboard.widgets.open_workspace", title: t(entry.title_key))) : nil
        }
      }
    end

    # Memoized per request: a load group is computed the first time a widget
    # from it appears on the page and shared by every later widget in it.
    def load_group(group, settings = {})
      @dashboard_load_groups ||= {}
      cache_settings = settings.slice("scope", "account_id", "security_id", "period", "grouping", "sort")
      cache_key = [ group, cache_settings ]
      return @dashboard_load_groups[cache_key] if @dashboard_load_groups.key?(cache_key)

      @dashboard_load_groups[cache_key] = send("load_#{group}_group", settings)
    end

    def load_research_news_group(_settings = {})
      ResearchNews.new(user: Current.user, source_unavailable: t("research.news.source_unavailable")).rows
    end

    def load_home_insights_group(_settings = {})
      Current.user.visible_insights.visible.ordered.limit(Insight::FEED_LIMIT)
    end

    def load_home_net_worth_group(_settings = {})
      Current.family.balance_sheet(user: Current.user)
    end

    def load_home_investments_group(_settings = {})
      Current.family.investment_statement(user: Current.user)
    end

    def load_home_cashflow_group(_settings = {})
      family_currency = Current.family.currency

      # Use IncomeStatement for all cashflow data (now includes categorized trades)
      income_statement = Current.family.income_statement(user: Current.user)
      income_totals = income_statement.income_totals(period: @period)
      expense_totals = income_statement.expense_totals(period: @period)
      net_totals = income_statement.net_category_totals(period: @period)

      money_flow_accounts = income_statement.eligible_accounts
      @money_flow_accounts = money_flow_accounts
      {
        sankey: build_cashflow_sankey_data(net_totals, income_totals, expense_totals, family_currency),
        outflows: build_outflows_donut_data(net_totals),
        money_flow_accounts: money_flow_accounts,
        # TransactionsController's default (account_ids absent) scopes to this
        # broader set, not the eligible accounts, so the widget needs it to
        # know when the drill-down links can safely omit account_ids.
        accessible_account_ids: Current.user.accessible_accounts.pluck(:id).map(&:to_s),
        money_flow: build_money_flow_data(income_statement, money_flow_month_param, money_flow_account_ids_param),
        spending_trend: build_spending_trend_data(income_statement, spending_trend_month_param)
      }
    end

    # nil when the center itself cannot say whether it is available; the
    # widgets then show their unavailable state rather than failing the page.
    def load_investment_decision_group(_settings = {})
      InvestmentDecisionCenter.new(user: Current.user)
    end

    def load_investment_holdings_group(settings = {})
      InvestmentAllocation.new(
        user: Current.user,
        by: settings["grouping"] || params[:by],
        account_id: dashboard_setting_account_id(settings)
      )
    rescue StandardError => e
      Rails.logger.warn("[dashboard] holdings widgets unavailable: #{e.class}: #{e.message}")
      nil
    end

    def load_portfolio_holdings_group(settings = {})
      PortfolioHoldings.new(
        user: Current.user,
        account_id: dashboard_setting_account_id(settings),
        sort: settings["sort"]
      )
    rescue StandardError => e
      Rails.logger.warn("[dashboard] portfolio widgets unavailable: #{e.class}: #{e.message}")
      nil
    end

    def load_investment_income_group(settings = {})
      InvestmentIncomeReview.new(
        user: Current.user,
        period: dashboard_setting_period(settings),
        account_id: dashboard_setting_account_id(settings)
      )
    rescue StandardError => e
      Rails.logger.warn("[dashboard] income widgets unavailable: #{e.class}: #{e.message}")
      nil
    end

    def load_investment_tax_group(_settings = {})
      {
        review: TaxLotReview.new(user: Current.user),
        harvest: TaxLossHarvest.new(user: Current.user)
      }
    rescue StandardError => e
      Rails.logger.warn("[dashboard] tax widget unavailable: #{e.class}: #{e.message}")
      nil
    end

    def load_investment_options_group(settings = {})
      OptionsReview.new(user: Current.user, sort: settings["sort"])
    rescue StandardError => e
      Rails.logger.warn("[dashboard] options widget unavailable: #{e.class}: #{e.message}")
      nil
    end

    def load_investment_events_group(_settings = {})
      builder = MarketCalendar::EventBuilder.new(accounts: Current.user.accessible_accounts.visible, now: Time.current)
      events = builder.events
      wash_events = events.select { |event| event.event_type == "wash_sale" && event.end_date >= Date.current }
      {
        events: events.select { |event| event.end_date >= Date.current },
        next_wash_deadline: wash_events.map(&:end_date).min,
        source_status: builder.wash_sale_status
      }
    rescue StandardError => e
      Rails.logger.warn("[dashboard] market events widget unavailable: #{e.class}: #{e.message}")
      nil
    end

    def load_investment_watchlist_group(_settings = {})
      active = Current.user.research_watchlist_entries.active
      {
        status_counts: ResearchWatchlistEntry::STATUSES.index_with { |status| active.where(status: status).count },
        priority_count: active.where(priority: 1..2).count
      }
    rescue StandardError => e
      Rails.logger.warn("[dashboard] watchlist widget unavailable: #{e.class}: #{e.message}")
      nil
    end

    def dashboard_setting_account_id(settings)
      settings["scope"] == "account" ? settings["account_id"] : nil
    end

    def dashboard_setting_period(settings)
      key = { "1m" => "last_30_days", "3m" => "last_90_days", "ytd" => "current_year", "1y" => "last_365_days" }[settings["period"]]
      key ? Period.from_key(key) : @period
    end

    # The add-widget dialog: every registry widget this member may use that is
    # not already on the page. Investment widgets are only offered to members
    # with investment access; the insights feed only with preview features.
    def dashboard_add_widget_options(page)
      {
        id: "dashboard-add-widget-dialog-#{page.fetch("id")}",
        url: page_widgets_path(page.fetch("id")),
        page_key: page.fetch("id"),
        widgets: helpers.dashboard_widget_catalog(existing: page.fetch("widgets").map { |widget| widget["key"] })
      }
    end

    def dashboard_page_management_options
      {
        pages: @dashboard_pages.map do |page|
          {
            id: page.fetch("id"),
            name: page.fetch("name"),
            custom: page.fetch("id").start_with?("p_"),
            update_url: page_path(page.fetch("id")),
            delete_url: page.fetch("id") == "home" ? nil : page_path(page.fetch("id"))
          }
        end,
        create_url: pages_path,
        templates: Dashboard::PageTemplateRegistry.all.filter_map do |template|
          next if template.widget_keys.any? { |key| Dashboard::WidgetRegistry.fetch(key).investment_required } && !Current.user.investment_dashboard_access?

          { key: template.key, name: template.name, account_scoped: template.account_scoped? }
        end,
        accounts: dashboard_scope_accounts.order(:name).pluck(:name, :id).map { |name, id| { name: name, id: id.to_s } },
        securities: dashboard_accessible_securities.map { |security| { label: "#{security.ticker} · #{security.name}", id: security.id.to_s } },
        draft_url: template_drafts_path,
        apply_draft_url: @dashboard_page.fetch("id").start_with?("p_") && @dashboard_page.fetch("widgets").empty? ? apply_draft_page_path(@dashboard_page.fetch("id")) : nil,
        order_url: order_pages_path,
        can_create: @dashboard_pages.size < User::MAX_DASHBOARD_PAGES,
        can_restore_investments: Current.user.investment_dashboard_access? &&
          @dashboard_pages.none? { |page| page.fetch("id") == "investments" } &&
          @dashboard_pages.size < User::MAX_DASHBOARD_PAGES
      }
    end

    def github_provider
      Provider::Registry.get_provider(:github)
    end

    def build_cashflow_sankey_data(net_totals, income_totals, expense_totals, currency)
      nodes = []
      links = []
      node_indices = {}

      add_node = ->(unique_key, display_name, value, percentage, color, filter_value = nil) {
        node_indices[unique_key] ||= begin
          nodes << { id: unique_key, name: display_name, filter_value: filter_value, value: value.to_f.round(2), percentage: percentage.to_f.round(1), color: color }
          nodes.size - 1
        end
      }

      total_income = net_totals.total_net_income.to_f.round(2)
      total_expense = net_totals.total_net_expense.to_f.round(2)

      # Central Cash Flow node
      cash_flow_idx = add_node.call("cash_flow_node", "Cash Flow", total_income, 100.0, "var(--color-success)")

      # Build netted subcategory data from raw totals
      net_subcategories_by_parent = build_net_subcategories(expense_totals, income_totals)

      # Process net income categories (flow: subcategory -> parent -> cash_flow)
      process_net_category_nodes(
        categories: net_totals.net_income_categories,
        total: total_income,
        prefix: "income",
        net_subcategories_by_parent: net_subcategories_by_parent,
        add_node: add_node,
        links: links,
        cash_flow_idx: cash_flow_idx,
        flow_direction: :inbound
      )

      # Process net expense categories (flow: cash_flow -> parent -> subcategory)
      process_net_category_nodes(
        categories: net_totals.net_expense_categories,
        total: total_expense,
        prefix: "expense",
        net_subcategories_by_parent: net_subcategories_by_parent,
        add_node: add_node,
        links: links,
        cash_flow_idx: cash_flow_idx,
        flow_direction: :outbound
      )

      # Surplus/Deficit
      net = (total_income - total_expense).round(2)
      if net.positive?
        percentage = total_income.zero? ? 0 : (net / total_income * 100).round(1)
        idx = add_node.call("surplus_node", "Surplus", net, percentage, "var(--color-success)")
        links << { source: cash_flow_idx, target: idx, value: net, color: "var(--color-success)", percentage: percentage }
      end

      { nodes: nodes, links: links, currency_symbol: Money::Currency.new(currency).symbol }
    end

    # Nets subcategory expense and income totals, grouped by parent_id.
    # Returns { parent_id => [ { category:, total: net_amount }, ... ] }
    # Only includes subcategories with positive net (same direction as parent).
    def build_net_subcategories(expense_totals, income_totals)
      expense_subs = expense_totals.category_totals
        .select { |ct| ct.category.parent_id.present? }
        .index_by { |ct| ct.category.id }

      income_subs = income_totals.category_totals
        .select { |ct| ct.category.parent_id.present? }
        .index_by { |ct| ct.category.id }

      all_sub_ids = (expense_subs.keys + income_subs.keys).uniq
      result = {}

      all_sub_ids.each do |sub_id|
        exp_ct = expense_subs[sub_id]
        inc_ct = income_subs[sub_id]
        exp_total = exp_ct&.total || 0
        inc_total = inc_ct&.total || 0
        net = exp_total - inc_total
        category = exp_ct&.category || inc_ct&.category

        next if net.zero?

        parent_id = category.parent_id
        result[parent_id] ||= []
        result[parent_id] << { category: category, total: net.abs, net_direction: net > 0 ? :expense : :income }
      end

      result
    end

    # Builds sankey nodes/links for net categories with subcategory hierarchy.
    # Subcategories matching the parent's flow direction are shown as children.
    # Subcategories with opposite net direction appear on the OTHER side of the
    # sankey (handled when the other side calls this method).
    #
    # flow_direction: :inbound  (subcategory -> parent -> cash_flow) for income
    #                 :outbound (cash_flow -> parent -> subcategory) for expenses
    def process_net_category_nodes(categories:, total:, prefix:, net_subcategories_by_parent:, add_node:, links:, cash_flow_idx:, flow_direction:)
      matching_direction = flow_direction == :inbound ? :income : :expense

      categories.each do |ct|
        val = ct.total.to_f.round(2)
        next if val.zero?

        percentage = total.zero? ? 0 : (val / total * 100).round(1)
        color = ct.category.color.presence || Category::UNCATEGORIZED_COLOR
        node_key = "#{prefix}_#{ct.category.id || ct.category.name}"

        all_subs = ct.category.id ? (net_subcategories_by_parent[ct.category.id] || []) : []
        same_side_subs = all_subs.select { |s| s[:net_direction] == matching_direction }

        # Also check if any subcategory has opposite direction — those will be
        # rendered by the OTHER side's call to this method, linked to cash_flow
        # directly (they appear as independent nodes on the opposite side).
        opposite_subs = all_subs.select { |s| s[:net_direction] != matching_direction }

        if same_side_subs.any?
          parent_idx = add_node.call(node_key, ct.category.name, val, percentage, color, ct.category.filter_value)

          if flow_direction == :inbound
            links << { source: parent_idx, target: cash_flow_idx, value: val, color: color, percentage: percentage }
          else
            links << { source: cash_flow_idx, target: parent_idx, value: val, color: color, percentage: percentage }
          end

          same_side_subs.each do |sub|
            sub_val = sub[:total].to_f.round(2)
            sub_pct = val.zero? ? 0 : (sub_val / val * 100).round(1)
            sub_color = sub[:category].color.presence || color
            sub_key = "#{prefix}_sub_#{sub[:category].id}"
            sub_idx = add_node.call(sub_key, sub[:category].name, sub_val, sub_pct, sub_color, sub[:category].filter_value)

            if flow_direction == :inbound
              links << { source: sub_idx, target: parent_idx, value: sub_val, color: sub_color, percentage: sub_pct }
            else
              links << { source: parent_idx, target: sub_idx, value: sub_val, color: sub_color, percentage: sub_pct }
            end
          end
        else
          idx = add_node.call(node_key, ct.category.name, val, percentage, color, ct.category.filter_value)

          if flow_direction == :inbound
            links << { source: idx, target: cash_flow_idx, value: val, color: color, percentage: percentage }
          else
            links << { source: cash_flow_idx, target: idx, value: val, color: color, percentage: percentage }
          end
        end

        # Render opposite-direction subcategories as standalone nodes on this side,
        # linked directly to cash_flow. They represent subcategory surplus/deficit
        # that goes against the parent's overall direction.
        opposite_prefix = flow_direction == :inbound ? "expense" : "income"
        opposite_subs.each do |sub|
          sub_val = sub[:total].to_f.round(2)
          sub_pct = total.zero? ? 0 : (sub_val / total * 100).round(1)
          sub_color = sub[:category].color.presence || color
          sub_key = "#{opposite_prefix}_sub_#{sub[:category].id}"
          sub_idx = add_node.call(sub_key, sub[:category].name, sub_val, sub_pct, sub_color, sub[:category].filter_value)

          # Opposite direction: if parent is outbound (expense), this sub is inbound (income)
          if flow_direction == :inbound
            links << { source: cash_flow_idx, target: sub_idx, value: sub_val, color: sub_color, percentage: sub_pct }
          else
            links << { source: sub_idx, target: cash_flow_idx, value: sub_val, color: sub_color, percentage: sub_pct }
          end
        end
      end
    end

    def build_outflows_donut_data(net_totals)
      currency_symbol = Money::Currency.new(net_totals.currency).symbol
      total = net_totals.total_net_expense

      categories = net_totals.net_expense_categories
        .reject { |ct| ct.total.zero? }
        .sort_by { |ct| -ct.total }
        .map do |ct|
          {
            id: ct.category.id,
            name: ct.category.name,
            filter_value: ct.category.filter_value,
            amount: ct.total.to_f.round(2),
            currency: ct.currency,
            percentage: ct.weight.round(1),
            color: ct.category.color.presence || Category::UNCATEGORIZED_COLOR,
            icon: ct.category.lucide_icon,
            clickable: !ct.category.other_investments?
          }
        end

      { categories: categories, total: total.to_f.round(2), currency: net_totals.currency, currency_symbol: currency_symbol }
    end

    def money_flow_month_param
      current_month = Date.current.beginning_of_month
      month = Date.strptime(params[:money_flow_month], "%Y-%m-%d").beginning_of_month
      # Clamp future months: build_money_flow_data caps each bar's end_date at
      # Date.current, which would otherwise be earlier than a future month's
      # start_date and blow up Period.custom's date-range validation.
      month > current_month ? current_month : month
    rescue ArgumentError, TypeError
      current_month
    end

    # nil means "all accessible accounts" (the widget's default, unfiltered state)
    def money_flow_account_ids_param
      ids = Array(params[:money_flow_account_ids]).reject(&:blank?)
      eligible_ids = @money_flow_accounts.map { |a| a.id.to_s }
      ids &= eligible_ids
      ids.presence
    end

    def spending_trend_month_param
      current_month = Date.current.beginning_of_month
      month = Date.strptime(params[:spending_month], "%Y-%m-%d").beginning_of_month
      # Same clamp as money_flow: a future month's period would end before it
      # starts once capped at Date.current, which Period.custom rejects.
      month > current_month ? current_month : month
    rescue ArgumentError, TypeError
      current_month
    end

    # Cumulative daily spending for the selected month (capped at today while
    # the month is in progress) against the previous month's full curve, so
    # the two lines share one day-of-month axis. The header totals compare the
    # same number of elapsed days; only the chart draws the previous month out
    # to its final day.
    def build_spending_trend_data(income_statement, selected_month)
      month_start = selected_month.beginning_of_month
      month_end = month_start.end_of_month
      current_period = Period.custom(start_date: month_start, end_date: [ month_end, Date.current ].min)

      previous_month_start = (month_start - 1.month).beginning_of_month
      previous_period = Period.custom(start_date: previous_month_start, end_date: previous_month_start.end_of_month)

      current_daily = income_statement.daily_expense_series(period: current_period).index_by(&:date)
      previous_daily = income_statement.daily_expense_series(period: previous_period).index_by(&:date)

      # The selected month always owns the axis: when the previous month is
      # longer, its extra days fold into the final visible point so the curve
      # still ends at the full-month total without the axis rolling into
      # previous-month dates (e.g. a September view ends at "Sep 30", not
      # "Aug 31").
      axis_days = month_end.day

      current_series = cumulative_spending_series(current_period, current_daily)
      previous_header_series = cumulative_spending_series(previous_period, previous_daily)
      previous_series = fold_extra_days(previous_header_series, axis_days)

      current_total = current_series.last&.fetch(:value) || 0
      comparison_days = if month_start == Date.current.beginning_of_month
        [ current_series.size, previous_header_series.size ].min
      else
        previous_header_series.size
      end
      previous_total = comparison_days.positive? ? previous_header_series[comparison_days - 1][:value] : 0
      previous_comparison_day = comparison_days if comparison_days.positive? && comparison_days < previous_header_series.size
      currency = income_statement.family.currency


      {
        month: month_start,
        current_period: current_period,
        previous_period: previous_period,
        days: axis_days,
        current_days: month_end.day,
        axis_labels: spending_trend_axis_labels(month_start, axis_days),
        current: current_series,
        previous: previous_series,
        current_total: Money.new(current_total, currency),
        previous_total: Money.new(previous_total, currency),
        delta: Money.new(current_total - previous_total, currency),
        previous_label: I18n.l(previous_month_start, format: :month_year).capitalize,
        previous_comparison_day: previous_comparison_day,
        date_range_short: spending_trend_compact_date_range(current_period)
      }
    end

    # Compact range for narrow viewports ("Sep 01 - 6, 2026"). The period
    # never spans months, so the end date only needs its day.
    def spending_trend_compact_date_range(period)
      date_range = period.date_range

      if date_range.begin == date_range.end
        t("pages.dashboard.spending_trend.date_range_short_single",
          date: I18n.l(date_range.begin, format: :short),
          year: date_range.end.year)
      else
        t("pages.dashboard.spending_trend.date_range_short",
          start_date: I18n.l(date_range.begin, format: :short),
          end_day: date_range.end.day,
          year: date_range.end.year)
      end
    end

    # Localized tick labels, one per axis day. The axis always spans exactly
    # the selected month, so labels never roll into the previous month.
    def spending_trend_axis_labels(month_start, days)
      (1..days).map do |day|
        I18n.l(month_start + (day - 1), format: :short)
      end
    end

    # A longer previous month's curve is clipped to the axis, with the extra
    # days' spend folded into the final visible point, so the curve still
    # ends at the full-month total shown in the header. The folded point
    # keeps its axis slot (day) for positioning but carries the true
    # endpoint's date metadata, so the tooltip says what the value actually
    # contains (e.g. "Jan 31" and the total through Jan 31).
    def fold_extra_days(series, axis_days)
      return series if series.size <= axis_days

      series.first(axis_days).tap do |folded|
        folded[-1] = folded[-1].merge(
          value: series.last[:value],
          date: series.last[:date],
          date_formatted: series.last[:date_formatted]
        )
      end
    end

    # One point per day (spend-free days included) so flat stretches render
    # flat instead of being interpolated away.
    def cumulative_spending_series(period, daily_totals)
      cumulative = 0.to_d
      period.date_range.map do |date|
        cumulative += daily_totals[date] ? daily_totals[date].total.to_d : 0
        {
          day: (date - period.start_date).to_i + 1,
          value: cumulative.to_f.round(2),
          date: date.iso8601,
          date_formatted: I18n.l(date, format: :short)
        }
      end
    end

    def build_money_flow_data(income_statement, selected_month, account_ids)
      months = (MONEY_FLOW_CHART_MONTHS - 1).downto(0).map { |i| selected_month - i.months }

      selected_period = nil
      selected_totals = nil

      bars = months.map do |month_start|
        # Cap at today so an in-progress month (most commonly the current one)
        # doesn't report totals for its not-yet-arrived days.
        end_date = [ month_start.end_of_month, Date.current ].min
        period = Period.custom(start_date: month_start, end_date: end_date)
        totals = income_statement.totals_for(period, account_ids: account_ids)

        if month_start == selected_month
          selected_period = period
          selected_totals = totals
        end

        {
          date: month_start,
          label: I18n.l(month_start, format: :short_month_year),
          # Fallback for the axis when the full label does not fit its band.
          # `short_month_year` is only short in some locales — "Mar 2026" in
          # English, but "Mar de 2026" in ca/es/pt, which is wide enough to
          # collide with its neighbours on a phone. The bar chart measures the
          # rendered labels and drops to this when they overlap.
          short_label: I18n.l(month_start, format: "%b"),
          income: totals.income_money.amount.to_f.round(2),
          expense: totals.expense_money.amount.to_f.round(2),
          highlighted: month_start == selected_month,
          partial: end_date < month_start.end_of_month
        }
      end

      {
        bars: bars,
        period: selected_period,
        month: selected_month,
        income: selected_totals.income_money,
        expense: selected_totals.expense_money,
        balance: selected_totals.income_money - selected_totals.expense_money,
        account_ids: account_ids
      }
    end

    def ensure_intro_guest!
      return if Current.user&.guest?

      redirect_to root_path, alert: t("pages.intro.not_authorized", default: "Intro is only available to guest users.")
    end
end
