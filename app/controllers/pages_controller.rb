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

    def cached_ticker_news
      security_ids = Holding.where(account_id: Current.user.accessible_accounts.visible.select(:id)).select(:security_id).distinct
      SecurityResearchSnapshot.includes(security: :headline_analysis).where(security_id: security_ids).filter_map do |snapshot|
        Array(snapshot.section("news")).filter_map do |article|
          title = article["title"].to_s.squish
          next unless title.present? && article["link"].to_s.start_with?("https://")

          raw_source = article["source"].to_s.squish
          { title: title, url: article["link"], source: raw_source.presence || "Source unavailable", published_at: article["published"] || article["published_at"] || article["publishedAt"] || article["time"], tickers: Array(article["tickers"]).map(&:to_s).map(&:upcase), headline_sentiments: dashboard_headline_sentiments(snapshot.security, raw_source, title) }
        end
      end.flatten.uniq { |article| article[:url] }.sort_by { |article| article[:published_at].to_s }.reverse.first(8)
    end

    def dashboard_headline_sentiments(security, source, title)
      analysis = security.headline_analysis
      return [] unless analysis&.available?

      key = Digest::SHA256.hexdigest([source.to_s.squish, title.to_s.squish.truncate(Security::HeadlineToneAnalyzer::TITLE_LIMIT)].join("\u0000"))
      tone = analysis.payload.dig("articleTones", key, "tone").to_s
      Security::HeadlineToneAnalyzer::TONES.include?(tone) ? [{ ticker: security.ticker, tone: tone }] : []
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

        content = dashboard_widget_content(entry)
        layout = dashboard_widget_layout(definition, widget.fetch("layout"))

        {
          key: definition.key,
          legacy_key: entry.legacy_key,
          dom_id: page.fetch("id") == "home" ? "dashboard-section-#{entry.legacy_key}" : "dashboard-section-#{page.fetch("id")}-#{entry.legacy_key}",
          title: entry.title_key,
          partial: entry.partial,
          padded: entry.padded,
          collapsed: widget["collapsed"] == true,
          layout: layout,
          locals: dashboard_widget_locals(entry, content.fetch(:locals, {}), page, layout),
          unavailable: content[:unavailable],
          update_url: page_widget_path(page.fetch("id"), definition.key),
          remove_url: page_widget_path(page.fetch("id"), definition.key)
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

    def dashboard_widget_locals(entry, locals, page, layout)
      result = locals.dup
      result[:col_span] = layout.fetch(:col_span) if entry.key == "home.money_flow"
      return result if page.fetch("id") == "home" || !entry.key.start_with?("home.")

      prefix = "#{page.fetch("id")}-#{entry.legacy_key.dasherize}"
      result[:widget_id] = prefix
      result[:chart_id] = "#{prefix}-chart" if entry.key == "home.net_worth_chart"
      result[:dialog_id] = "#{prefix}-dialog" if entry.key == "home.cashflow_sankey"
      result
    end

    # Locals for the widget's partial, or an unavailable state when the data
    # behind it cannot be supplied. Everything is scoped to Current.user and
    # loaded at most once per registry load group.
    def dashboard_widget_content(entry)
      case entry.key
      when "home.ticker_news"
        articles = load_group(:home_news)
        articles.any? ? { locals: { articles: articles } } : unavailable_widget(entry, "no_news")
      when "home.insights_feed"
        insights = load_group(:home_insights)
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
      when "investments.decision_pulse"
        center = load_group(:investment_decision)
        center.available? ? { locals: { pulse: center.pulse } } : unavailable_widget(entry, "no_investments")
      when "investments.decision_action"
        center = load_group(:investment_decision)
        center.available? ? { locals: { actions: center.actions } } : unavailable_widget(entry, "no_investments")
      when "investments.decision_monitor"
        center = load_group(:investment_decision)
        center.available? ? { locals: { top_holdings: center.top_holdings, center: center } } : unavailable_widget(entry, "no_investments")
      when "investments.holdings_allocation"
        allocation = load_group(:investment_holdings)
        allocation ? { locals: { allocation: allocation, currency: allocation.currency } } : unavailable_widget(entry, "failed")
      when "investments.holdings_data_quality"
        allocation = load_group(:investment_holdings)
        allocation ? { locals: { issues: allocation.data_quality } } : unavailable_widget(entry, "failed")
      when "investments.income_performance", "investments.income_cash_flows"
        review = load_group(:investment_income)
        if review.nil?
          unavailable_widget(entry, "failed")
        elsif review.accounts.none?
          unavailable_widget(entry, "no_investments")
        else
          { locals: { review: review, currency: review.currency } }
        end
      end
    end

    def unavailable_widget(entry, reason)
      {
        unavailable: {
          message: t("pages.dashboard.widget_unavailable.#{reason}"),
          href: entry.canonical_route ? public_send("#{entry.canonical_route}_path") : nil,
          link_text: entry.canonical_route ? t("pages.dashboard.widget_unavailable.open_#{entry.canonical_route}") : nil
        }
      }
    end

    # Memoized per request: a load group is computed the first time a widget
    # from it appears on the page and shared by every later widget in it.
    def load_group(group)
      @dashboard_load_groups ||= {}
      return @dashboard_load_groups[group] if @dashboard_load_groups.key?(group)

      @dashboard_load_groups[group] = send("load_#{group}_group")
    end

    def load_home_news_group
      cached_ticker_news
    end

    def load_home_insights_group
      Current.user.visible_insights.visible.ordered.limit(Insight::FEED_LIMIT)
    end

    def load_home_net_worth_group
      Current.family.balance_sheet(user: Current.user)
    end

    def load_home_investments_group
      Current.family.investment_statement(user: Current.user)
    end

    def load_home_cashflow_group
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
    def load_investment_decision_group
      InvestmentDecisionCenter.new(user: Current.user)
    end

    def load_investment_holdings_group
      InvestmentAllocation.new(user: Current.user, by: params[:by])
    rescue StandardError => e
      Rails.logger.warn("[dashboard] holdings widgets unavailable: #{e.class}: #{e.message}")
      nil
    end

    def load_investment_income_group
      InvestmentIncomeReview.new(user: Current.user, period: @period)
    rescue StandardError => e
      Rails.logger.warn("[dashboard] income widgets unavailable: #{e.class}: #{e.message}")
      nil
    end

    # The add-widget dialog: every registry widget this member may use that is
    # not already on the page. Investment widgets are only offered to members
    # with investment access; the insights feed only with preview features.
    def dashboard_add_widget_options(page)
      {
        id: "dashboard-add-widget-dialog-#{page.fetch("id")}",
        url: page_widgets_path(page.fetch("id")),
        page_key: page.fetch("id"),
        widgets: helpers.dashboard_widget_catalog(except: page.fetch("widgets").map { |widget| widget["key"] })
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
