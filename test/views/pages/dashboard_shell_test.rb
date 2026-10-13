require "test_helper"

# The homepage's multi-page shell (page tabs, header actions, add-widget
# dialog, empty page) is a set of partials with explicit locals and no
# persistence of their own: the controller hands them translated titles,
# resolved paths and a named route to post to. These tests render each one on
# its own with such locals.
class DashboardShellTest < ActionView::TestCase
  include DashboardHelper

  setup do
    @user = users(:family_admin)
    Current.session = Session.create!(user: @user)
    @pages = [
      { key: "overview", title: "Overview", path: "/" },
      { key: "investing", title: "Investing", path: "/?page=investing" }
    ]
    @add_widget = { id: "add-widget-dialog", url: "/dashboard/pages/investing/widgets", page_key: "investing",
                    widgets: [ { key: :portfolio, label: "Portfolio", widgets: [ { key: "home.net_worth_chart", title: "Net Worth" }, { key: "home.balance_sheet", title: "Balance Sheet" } ] } ] }
    @page_management = {
      pages: [], create_url: "/dashboard/pages", templates: [ { key: "blank", name: "Blank page" } ], order_url: "/dashboard/pages/order",
      can_create: true, can_restore_investments: false
    }
  end

  test "page tabs mark the current page, swap the dashboard frame and name each page key" do
    html = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/page_tabs", locals: { pages: @pages, current: "investing" }))

    assert_select html, "nav[aria-label=?][data-testid=dashboard-page-tabs]", I18n.t("pages.dashboard.pages.label")
    assert_select html, "a[aria-current=page][href='/?page=investing'][data-dashboard-page-key=investing]", text: "Investing"
    assert_select html, "a[href='/'][data-turbo-frame=_top][data-turbo-action=advance][data-turbo-prefetch=false]", text: "Overview"
    assert_select html, "nav[data-testid=dashboard-page-tabs] a[aria-current]", count: 1
    assert_select html, "[data-testid=dashboard-page-switcher] a[aria-current]", count: 1

    hosts = html.css("[data-controller~='dashboard-pages']")
    assert_equal 2, hosts.size
    hosts.each do |host|
      assert_equal 1, host.css("[data-dashboard-pages-target=error][data-error-scope=local][role=alert]").size,
        "expected #{host['data-testid']} to own one local alert"
      assert host.at_css("[data-action*='dashboard-pages#selectPage']")
    end
  end

  test "phone page switcher names the current page and lists every direct route" do
    pages = @pages + [ { key: "long-page", title: "A very long custom dashboard page name", path: "/?page=long-page" } ]
    html = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/page_tabs", locals: { pages: pages, current: "long-page" }))

    assert_select html, "[data-controller~='dashboard-pages'][class*='hidden'][class*='md:block'] nav[data-testid=dashboard-page-tabs]"
    assert_select html, "[data-testid=dashboard-page-switcher][class*='md:hidden'][data-controller~='dialog-trigger']"
    assert_select html, "button[data-testid=dashboard-page-switcher-trigger][aria-haspopup=dialog][aria-expanded=false][aria-controls=dashboard-page-switcher-dialog]",
      text: /A very long custom dashboard page name/
    assert_select html, "dialog#dashboard-page-switcher-dialog[aria-modal=true][aria-labelledby]"
    pages.each do |page|
      assert_select html, "dialog#dashboard-page-switcher-dialog a[href=?][data-dashboard-page-key=?]", page[:path], page[:key], text: page[:title]
    end
    assert_select html, "dialog#dashboard-page-switcher-dialog a[aria-current=page][href='/?page=long-page']"
    assert_select html, "[data-testid=dashboard-page-switcher-create][data-action='click->dialog-trigger#handoffToFocus'][data-dialog-trigger-handoff-id=dashboard-manage-pages-dialog][data-dialog-trigger-focus-id=dashboard-new-page-name]",
      text: I18n.t("pages.dashboard.pages.create")
    assert_select html, "[data-testid=dashboard-page-switcher-manage][data-action='click->dialog-trigger#handoff'][data-dialog-trigger-handoff-id=dashboard-manage-pages-dialog]",
      text: I18n.t("pages.dashboard.pages.switcher_manage")
    assert_select html, "[data-dialog-trigger-target=message][role=alert]"
    assert_includes html.text, I18n.t("pages.dashboard.pages.switcher_label")
  end

  test "page creation controls stay gated by can_create" do
    tabs = Nokogiri::HTML.fragment(render(
      partial: "pages/dashboard/page_tabs",
      locals: { pages: @pages, current: "overview", can_create: false }
    ))
    dialog = Nokogiri::HTML.fragment(render(
      partial: "pages/dashboard/manage_pages_dialog",
      locals: @page_management.merge(can_create: false)
    ))

    assert_select tabs, "[data-testid=dashboard-page-switcher-create]", count: 0
    assert_select tabs, "[data-testid=dashboard-page-switcher-manage]", count: 1
    assert_select dialog, "form#dashboard-create-page", count: 0
  end

  test "a single page still renders the permanent Home tab" do
    html = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/page_tabs", locals: { pages: @pages.first(1), current: "overview" }))

    assert_select html, "nav[data-testid=dashboard-page-tabs] a[aria-current=page]", text: "Overview"
  end

  test "the add-widget dialog sends each offered registered key to the given route" do
    html = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/add_widget_dialog", locals: @add_widget))

    assert_select html, "dialog#add-widget-dialog[data-testid=dashboard-add-widget-dialog]"
    assert_select html, "[data-testid=dashboard-widget-catalog] li", count: 2
    assert_select html, "button[data-action='click->dashboard-pages#addWidget'][data-url='/dashboard/pages/investing/widgets'][data-page-key=investing]", count: 2
    assert_select html, "button[data-widget-key='home.net_worth_chart']", count: 1
    assert_select html, "button[data-widget-key='home.balance_sheet'][aria-label=?]", I18n.t("pages.dashboard.widgets.add_to_page", title: "Balance Sheet")
  end

  test "an exhausted catalog shows an empty state instead of an empty list" do
    html = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/add_widget_dialog", locals: @add_widget.merge(widgets: [])))

    assert_select html, "[data-testid=dashboard-widget-catalog]", count: 0
    assert_select html, "dialog", text: /#{I18n.t("pages.dashboard.widgets.none_left_title")}/
  end

  test "header actions offer widget, page-management and account controls" do
    html = Nokogiri::HTML.fragment(render(
      partial: "pages/dashboard/header_actions",
      locals: {
        add_widget: @add_widget,
        page_management: @page_management,
        current_page_url: "/?page=investing",
        home_url: "/"
      }
    ))

    assert_select html, "[data-testid=dashboard-header-actions] a[href=?]", "/accounts/new", minimum: 1
    assert_select html, "[data-controller~='dashboard-pages'][data-dashboard-pages-return-url-value='/?page=investing'] [data-testid=dashboard-add-widget]"
    assert_select html, "dialog#add-widget-dialog"
    assert_select html, "[data-testid=dashboard-manage-pages]"
    assert_select html, "dialog#dashboard-manage-pages-dialog"

    hosts = html.css("[data-testid=dashboard-header-actions] > [data-controller~='dashboard-pages']")
    assert_equal 2, hosts.size
    hosts.each do |host|
      local_alerts = host.xpath("./p[@data-dashboard-pages-target='error'][@data-error-scope='local'][@role='alert']")
      assert_equal 1, local_alerts.size, "expected each header controller to own a direct fallback alert"
    end
    assert_select html, "#add-widget-dialog-error[data-dashboard-pages-target=error][role=alert]"
    assert_select html, "[data-testid=dashboard-widget-catalog][data-error-target-id=add-widget-dialog-error]"
    assert_select html, "[data-dashboard-pages-order-error-value=?]", I18n.t("pages.dashboard.pages.order_unavailable")
  end

  test "every rendered dashboard-pages host owns a visible error destination" do
    fragments = [
      render(partial: "pages/dashboard/page_tabs", locals: { pages: @pages, current: "investing" }),
      render(
        partial: "pages/dashboard/header_actions",
        locals: {
          add_widget: @add_widget,
          page_management: @page_management,
          current_page_url: "/?page=investing",
          home_url: "/"
        }
      ),
      render(
        partial: "pages/dashboard/empty_page",
        locals: { title: "Nothing here", description: "Add something.", add_widget: @add_widget, current_page_url: "/?page=investing" }
      ),
      render(partial: "pages/dashboard/view_switch", locals: { active: "overview" })
    ]
    html = Nokogiri::HTML.fragment(fragments.join)
    hosts = html.css("[data-controller~='dashboard-pages']")

    assert_equal 6, hosts.size
    hosts.each do |host|
      targets = host.css("[data-dashboard-pages-target=error][role=alert]").reject do |target|
        target["data-error-scope"] == "form"
      end
      assert targets.any?, "dashboard-pages host lacks a visible alert: #{host.to_html.first(180)}"
    end

    dashboard = Rails.root.join("app/views/pages/dashboard.html.erb").read
    assert_match(/render "pages\/dashboard\/local_error", id: "dashboard-page-alert", scope: "page"/, dashboard)
    assert_equal 2, dashboard.scan(/data-error-target-id="dashboard-page-alert"/).size
  end

  test "manage-page mutations explicitly target the dialog alert" do
    pages = [
      { id: "home", name: "Home", custom: false },
      { id: "p_planning", name: "Planning", custom: true, update_url: "/dashboard/pages/p_planning", delete_url: "/dashboard/pages/p_planning" },
      { id: "investments", name: "Investments", custom: false }
    ]
    html = Nokogiri::HTML.fragment(render(
      partial: "pages/dashboard/manage_pages_dialog",
      locals: @page_management.merge(
        pages: pages,
        draft_url: "/dashboard/pages/draft",
        apply_draft_url: "/dashboard/pages/p_planning/draft",
        can_restore_investments: true
      )
    ))

    target = "dashboard-manage-pages-error"
    assert_select html, "[data-error-target-id=#{target}]", minimum: 8
    assert_select html, "##{target}[data-dashboard-pages-target=error][data-error-scope=manage-pages][role=alert]"
    assert_select html, "form#dashboard-create-page[data-action='submit->dashboard-pages#createPage'][data-error-target-id=#{target}]"
    assert_select html, "form[data-action='submit->dashboard-pages#renamePage'][data-error-target-id=#{target}]", count: 1
    assert_select html, "button[data-action='click->dashboard-pages#deletePage'][data-error-target-id=#{target}]", count: 1
    assert_select html, "button[data-action='click->dashboard-pages#movePageUp'][data-error-target-id=#{target}]", minimum: 1
    assert_select html, "button[data-action='click->dashboard-pages#movePageDown'][data-error-target-id=#{target}]", minimum: 1
    assert_select html, "form[data-action='submit->dashboard-pages#previewDraft'][data-error-target-id=#{target}]"
    assert_select html, "button[data-action='click->dashboard-pages#createFromDraft'][data-error-target-id=#{target}]"
    assert_select html, "button[data-action='click->dashboard-pages#applyDraft'][data-error-target-id=#{target}]"
    assert_select html, "button[data-action='click->dashboard-pages#restoreInvestments'][data-error-target-id=#{target}]"
  end

  test "dashboard page errors resolve to one alert in priority order" do
    source = Rails.root.join("app/javascript/controllers/dashboard_pages_controller.js").read

    assert_includes source, "const explicitTarget = targetId ? document.getElementById(targetId) : null;"
    assert_includes source, 'element?.closest("dialog")'
    assert_includes source, 'target.dataset.errorScope === "local"'
    assert_includes source, 'target.dataset.errorScope === "page"'
    assert_includes source, "const target = this._errorTargets(errorTarget)[0];"
    refute_includes source, "_visitAfterError"
    refute_includes source, "console.error"
  end

  test "dashboard error alerts are programmatically focusable without autofocus" do
    fragments = [
      render(partial: "pages/dashboard/page_tabs", locals: { pages: @pages, current: "investing" }),
      render(partial: "pages/dashboard/add_widget_dialog", locals: @add_widget),
      render(partial: "pages/dashboard/manage_pages_dialog", locals: @page_management)
    ]
    html = Nokogiri::HTML.fragment(fragments.join)
    alerts = html.css("[data-dashboard-pages-target=error][role=alert]")

    assert alerts.any?
    alerts.each do |alert|
      assert_equal "-1", alert["tabindex"]
      refute alert.key?("autofocus")
    end
  end

  test "mobile create handoff focuses and scrolls the existing create form control" do
    source = Rails.root.join("app/javascript/controllers/dialog_trigger_controller.js").read

    assert_includes source, "handoffToFocus(event)"
    assert_includes source, "event.currentTarget.dataset.dialogTriggerFocusId"
    assert_includes source, "focusTarget.focus({ preventScroll: true })"
    assert_includes source, 'focusTarget.scrollIntoView({ block: "center" })'
  end

  test "the empty page offers Add widget with its own dialog" do
    html = Nokogiri::HTML.fragment(render(
      partial: "pages/dashboard/empty_page",
      locals: { title: "Nothing here", description: "Add something.", add_widget: @add_widget, current_page_url: "/?page=investing" }
    ))

    assert_select html, "[data-testid=dashboard-empty-page]", text: /Nothing here/
    assert_select html, "[data-testid=dashboard-empty-page] [data-dashboard-pages-target=error][data-error-scope=local][role=alert]"
    assert_select html, "[data-controller~='dashboard-pages'][data-dashboard-pages-return-url-value='/?page=investing'] button[data-action='click->expandable#open']", text: /#{I18n.t("pages.dashboard.widgets.add")}/
    assert_select html, "dialog#add-widget-dialog-empty"
  end

  test "view switch has a local visible error destination" do
    html = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/view_switch", locals: { active: "overview" }))

    assert_select html, "[data-controller=dashboard-pages] [data-dashboard-pages-target=error][data-error-scope=local][role=alert]"
  end

  test "the widget catalog is the member-accessible registry with translated titles" do
    catalog = dashboard_widget_catalog(except: %w[home.net_worth_chart])
    expected = Dashboard::WidgetRegistry.keys - %w[home.insights_feed home.net_worth_chart]

    widgets = catalog.flat_map { |group| group[:widgets] }
    assert_equal expected.sort, widgets.map { |widget| widget[:key] }.sort
    assert_equal I18n.t("pages.dashboard.balance_sheet.title"), widgets.find { |widget| widget[:key] == "home.balance_sheet" }[:title]
    assert_equal I18n.t("pages.dashboard.investment_widgets.income_performance"), widgets.find { |widget| widget[:key] == "investments.income_performance" }[:title]
    assert_equal Dashboard::WidgetCatalog::GROUPS & catalog.map { |group| group[:key] }, catalog.map { |group| group[:key] }
  end

  test "widget picker exposes one canonical News option with localized setting preview" do
    widgets = dashboard_widget_catalog.flat_map { |group| group[:widgets] }
    news = widgets.select { |widget| widget[:key] == "research.news" }

    assert_equal 1, news.size
    assert_equal I18n.t("pages.dashboard.ticker_news.title"), news.sole.fetch(:title)
    assert_equal %w[scope account_id security_id period rows sort filter density sentiment], news.sole.fetch(:settings).map { |setting| setting.fetch(:key) }
    assert_equal "All available", news.sole.fetch(:settings).find { |setting| setting[:key] == "period" }.fetch(:options).first.first

    html = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/add_widget_dialog", locals: @add_widget.merge(widgets: [ { key: :research, label: "Research", widgets: news } ])))
    assert_select html, "[data-widget-key='research.news']", count: 1
    assert_select html, "form[data-controller=widget-settings] select[name=scope][aria-describedby][data-widget-settings-target=scope][data-action='change->widget-settings#scopeChanged']"
    assert_select html, "select[name=account_id][disabled]"
    assert_select html, "select[name=security_id][disabled]"
  end

  test "widget picker warns about a decision overlap without blocking a scoped alternative" do
    widgets = dashboard_widget_catalog(existing: %w[portfolio.pulse]).flat_map { |group| group[:widgets] }
    workspace = widgets.find { |widget| widget[:key] == "investments.decision_center" }

    assert_equal "portfolio.pulse", workspace.fetch(:overlap_with_key)
    assert_equal I18n.t("pages.dashboard.granular_widgets.portfolio_pulse"), workspace.fetch(:overlap_with_title)
    assert_nil widgets.find { |widget| widget[:key] == "research.news" }.fetch(:overlap_with_key)

    html = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/add_widget_dialog", locals: @add_widget.merge(widgets: [ { key: :review, label: "Review", widgets: [ workspace ] } ])))
    assert_select html, "form:has(button[data-widget-key='investments.decision_center']) [data-testid='widget-overlap-warning']", text: /#{Regexp.escape(I18n.t("pages.dashboard.widgets.overlap_warning", title: workspace.fetch(:overlap_with_title)))}/
  end

  test "KPI tile does not duplicate a privacy-sensitive value into its title" do
    value = tag.span("$1,234.00", class: "privacy-sensitive", title: "$1,234.00")
    html = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/widgets/kpi_tile", locals: { label: "Value", value: value }))

    assert_select html, "p.text-xl:not([title]) .privacy-sensitive[title='$1,234.00']", text: "$1,234.00"
  end

  test "chart widgets take a per-instance DOM id so two copies cannot collide" do
    balance_sheet = @user.family.balance_sheet
    period = Period.last_30_days

    first = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/net_worth_chart", locals: { balance_sheet: balance_sheet, period: period }))
    second = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/net_worth_chart",
                                            locals: { balance_sheet: balance_sheet, period: period, widget_id: "page2-net-worth", chart_id: "page2-net-worth-chart" }))

    assert_select first, "#net-worth-chart"
    assert_select second, "#page2-net-worth"
    assert_select second, "#net-worth-chart", count: 0

    sheet = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/balance_sheet", locals: { balance_sheet: balance_sheet, widget_id: "page2-balance-sheet" }))
    assert_select sheet, "#page2-balance-sheet"
    assert_select sheet, "#balance-sheet", count: 0
  end
end
