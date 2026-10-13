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
    assert_select html, "a[aria-current]", count: 1
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
  end

  test "the empty page offers Add widget with its own dialog" do
    html = Nokogiri::HTML.fragment(render(
      partial: "pages/dashboard/empty_page",
      locals: { title: "Nothing here", description: "Add something.", add_widget: @add_widget, current_page_url: "/?page=investing" }
    ))

    assert_select html, "[data-testid=dashboard-empty-page]", text: /Nothing here/
    assert_select html, "[data-controller~='dashboard-pages'][data-dashboard-pages-return-url-value='/?page=investing'] button[data-action='click->expandable#open']", text: /#{I18n.t("pages.dashboard.widgets.add")}/
    assert_select html, "dialog#add-widget-dialog-empty"
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
