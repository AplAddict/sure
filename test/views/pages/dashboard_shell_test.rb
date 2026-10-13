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
                    widgets: [ { key: "net_worth_chart", title: "Net Worth" }, { key: "balance_sheet", title: "Balance Sheet" } ] }
  end

  test "page tabs mark the current page, swap the dashboard frame and name each page key" do
    html = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/page_tabs", locals: { pages: @pages, current: "investing" }))

    assert_select html, "nav[aria-label=?][data-testid=dashboard-page-tabs]", I18n.t("pages.dashboard.pages.label")
    assert_select html, "a[aria-current=page][href='/?page=investing'][data-dashboard-page-key=investing]", text: "Investing"
    assert_select html, "a[href='/'][data-turbo-frame=dashboard_sections][data-turbo-action=advance]", text: "Overview"
    assert_select html, "a[aria-current]", count: 1
  end

  test "a single page renders no tab strip" do
    html = render(partial: "pages/dashboard/page_tabs", locals: { pages: @pages.first(1), current: "overview" })

    assert_equal "", html.strip
  end

  test "the add-widget dialog posts each offered widget and page key to the given route" do
    html = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/add_widget_dialog", locals: @add_widget))

    assert_select html, "dialog#add-widget-dialog[data-testid=dashboard-add-widget-dialog]"
    assert_select html, "[data-testid=dashboard-widget-catalog] li", count: 2
    assert_select html, "form[action='/dashboard/pages/investing/widgets'][method=post]", count: 2
    assert_select html, "input[name=page_key][value=investing]", count: 2
    assert_select html, "input[name=widget_key][value=net_worth_chart]", count: 1
    assert_select html, "button[data-dashboard-widget-key=balance_sheet][aria-label=?]", I18n.t("pages.dashboard.widgets.add_to_page", title: "Balance Sheet")
  end

  test "an exhausted catalog shows an empty state instead of an empty list" do
    html = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/add_widget_dialog", locals: @add_widget.merge(widgets: [])))

    assert_select html, "[data-testid=dashboard-widget-catalog]", count: 0
    assert_select html, "dialog", text: /#{I18n.t("pages.dashboard.widgets.none_left_title")}/
  end

  test "header actions offer Add widget only when a page can be edited" do
    plain = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/header_actions", locals: {}))
    assert_select plain, "[data-testid=dashboard-header-actions] a[href=?]", "/accounts/new", minimum: 1
    assert_select plain, "[data-testid=dashboard-add-widget]", count: 0
    assert_select plain, "dialog", count: 0

    editable = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/header_actions", locals: { add_widget: @add_widget }))
    assert_select editable, "[data-controller=expandable] [data-testid=dashboard-add-widget][data-action='click->expandable#open']"
    assert_select editable, "[data-controller=expandable] dialog#add-widget-dialog"
  end

  test "the empty page offers Add widget with its own dialog only when a page can be edited" do
    plain = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/empty_page", locals: { title: "Nothing here", description: "Add something." }))
    assert_select plain, "[data-testid=dashboard-empty-page]", text: /Nothing here/
    assert_select plain, "button", count: 0

    editable = Nokogiri::HTML.fragment(render(partial: "pages/dashboard/empty_page", locals: { title: "Nothing here", description: "Add something.", add_widget: @add_widget }))
    assert_select editable, "[data-controller=expandable] button[data-action='click->expandable#open']", text: /#{I18n.t("pages.dashboard.widgets.add")}/
    assert_select editable, "dialog#add-widget-dialog-empty"
  end

  test "the widget catalog is the dashboard's own widget registry with translated titles" do
    catalog = dashboard_widget_catalog(except: %w[net_worth_chart])

    assert_equal PagesController::DASHBOARD_SECTION_LAYOUTS.keys - %w[net_worth_chart], catalog.map { |w| w[:key] }
    assert_equal I18n.t("pages.dashboard.balance_sheet.title"), catalog.find { |w| w[:key] == "balance_sheet" }[:title]
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
