require "test_helper"

class DashboardPagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: {})
    sign_in @user
  end

  test "index returns read-forward pages and registry" do
    get "/dashboard/pages", as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal %w[home investments], body.fetch("pages").map { |page| page.fetch("id") }
    assert_equal "home", body.fetch("current_page")
    assert_includes body.fetch("widget_registry").map { |widget| widget.fetch("key") }, "investments.income_performance"
    assert_not @user.reload.preferences.key?("dashboard_pages")
  end

  test "creates renames selects and deletes a custom page" do
    post "/dashboard/pages", params: { page: { name: "  Planning  " } }, as: :json
    assert_response :created
    page = JSON.parse(response.body).fetch("page")
    assert_match(/\Ap_[0-9a-z]{8}\z/, page.fetch("id"))

    patch "/dashboard/pages/#{page.fetch("id")}", params: { page: { name: "Plan" } }, as: :json
    assert_response :success
    assert_equal "Plan", JSON.parse(response.body).dig("page", "name")

    patch "/dashboard/pages/current", params: { page_id: page.fetch("id") }, as: :json
    assert_response :success
    assert_equal page.fetch("id"), @user.reload.preferences.fetch("dashboard_current_page")

    delete "/dashboard/pages/#{page.fetch("id")}", as: :json
    assert_response :no_content
    assert_equal "home", @user.reload.preferences.fetch("dashboard_current_page")
  end

  test "widget endpoints add update order and remove only registered widgets" do
    post "/dashboard/pages", params: { page: { name: "Widgets" } }, as: :json
    page_id = JSON.parse(response.body).dig("page", "id")

    post "/dashboard/pages/#{page_id}/widgets", params: { widget: { key: "home.spending_trend" } }, as: :json
    assert_response :created
    spending = response.parsed_body.fetch("widget")

    post "/dashboard/pages/#{page_id}/widgets", params: { widget: { key: "home.balance_sheet" } }, as: :json
    assert_response :created
    balance = response.parsed_body.fetch("widget")

    patch page_widget_path(page_id, spending.fetch("id")), params: { widget: { collapsed: true, layout: { col_width: 12, height: 6 } } }, as: :json
    assert_response :success
    widget = JSON.parse(response.body).fetch("widget")
    assert widget.fetch("collapsed")
    assert_equal({ "col_width" => 12, "height" => 6 }, widget.fetch("layout"))

    patch order_page_widgets_path(page_id), params: { instance_ids: [ balance.fetch("id"), spending.fetch("id") ] }, as: :json
    assert_response :success
    assert_equal [ balance.fetch("id"), spending.fetch("id") ], response.parsed_body.fetch("page").fetch("widgets").map { |row| row.fetch("id") }

    delete page_widget_path(page_id, spending.fetch("id")), as: :json
    assert_response :no_content
    assert_not_includes @user.reload.dashboard_pages.find { |page| page["id"] == page_id }["widgets"].map { |row| row["id"] }, spending.fetch("id")
  end

  test "invalid widget layouts and duplicate adds return 422 atomically" do
    post "/dashboard/pages", params: { page: { name: "Widgets" } }, as: :json
    page_id = JSON.parse(response.body).dig("page", "id")
    post "/dashboard/pages/#{page_id}/widgets", params: { widget: { key: "home.spending_trend" } }, as: :json
    assert_response :created
    spending_id = response.parsed_body.dig("widget", "id")
    post "/dashboard/pages/#{page_id}/widgets", params: { widget: { key: "home.outflows_donut" } }, as: :json
    assert_response :created
    outflows_id = response.parsed_body.dig("widget", "id")
    original = @user.reload.preferences.deep_dup

    post "/dashboard/pages/#{page_id}/widgets", params: { widget: { key: "home.spending_trend" } }, as: :json
    assert_response :unprocessable_entity
    assert_equal "an identical widget already exists on page", JSON.parse(response.body).fetch("message")
    assert_equal original, @user.reload.preferences

    [
      [ spending_id, { col_width: 7 } ],
      [ spending_id, { height: 5 } ],
      [ spending_id, { width: 12 } ],
      [ spending_id, "invalid" ],
      [ outflows_id, { col_width: 12 } ]
    ].each do |instance_id, layout|
      patch page_widget_path(page_id, instance_id), params: { widget: { collapsed: true, layout: layout } }, as: :json
      assert_response :unprocessable_entity
      assert_equal original, @user.reload.preferences
    end

    patch page_widget_path(page_id, spending_id), params: { widget: { layout: { col_width: 12, height: 6 } } }, as: :json
    assert_response :success
  end

  test "removes and explicitly restores Investments while Home stays permanent" do
    delete "/dashboard/pages/investments", as: :json
    assert_response :no_content
    assert_equal [ "home" ], @user.reload.dashboard_pages.map { |page| page["id"] }

    get root_path(page: "investments")
    assert_response :success
    assert_no_match I18n.t("investment_decision_center.title"), response.body
    assert_equal [ "home" ], @user.reload.dashboard_pages.map { |page| page["id"] }
    assert_select "button[data-action*='restoreInvestments'][data-url=?]", pages_path

    delete "/dashboard/pages/home", as: :json
    assert_response :unprocessable_entity
    assert_equal [ "home" ], @user.reload.dashboard_pages.map { |page| page["id"] }

    post "/dashboard/pages", params: { page: { id: "investments", name: nil } }, as: :json
    assert_response :created
    assert_equal "Investments", JSON.parse(response.body).dig("page", "name")
    assert_equal %w[home investments], @user.reload.dashboard_pages.map { |page| page["id"] }
  end

  test "page order requires every unique page id and keeps Home pinned first" do
    post "/dashboard/pages", params: { page: { name: "Planning" } }, as: :json
    custom_id = JSON.parse(response.body).dig("page", "id")
    original = @user.reload.preferences.deep_dup

    [
      [ "home", custom_id ],
      [ "home", "investments", "investments" ],
      [ "investments", "home", custom_id ],
      [ "home", "investments", "not-a-page" ]
    ].each do |page_ids|
      patch "/dashboard/pages/order", params: { page_ids: page_ids }, as: :json
      assert_response :unprocessable_entity
      assert_equal original, @user.reload.preferences
    end

    patch "/dashboard/pages/order", params: { page_ids: [ "home", custom_id, "investments" ] }, as: :json
    assert_response :success
    assert_equal [ "home", custom_id, "investments" ], JSON.parse(response.body).fetch("pages").map { |page| page.fetch("id") }
  end

  test "malformed page and widget objects return validation errors without storage" do
    custom = @user.create_dashboard_page!("Payloads")
    home_balance_id = @user.dashboard_pages.find { |page| page["id"] == "home" }.fetch("widgets").find { |widget| widget["key"] == "home.balance_sheet" }.fetch("id")
    original = @user.reload.preferences.deep_dup
    requests = [
      [ :post, pages_path, :page ],
      [ :patch, page_path(custom.fetch("id")), :page ],
      [ :post, page_widgets_path(custom.fetch("id")), :widget ],
      [ :patch, page_widget_path("home", home_balance_id), :widget ]
    ]

    requests.each do |method, path, root_key|
      [ "invalid", [], nil ].each do |payload|
        public_send(method, path, params: { root_key => payload }, as: :json)

        assert_response :unprocessable_entity, "expected #{method.upcase} #{path} with #{payload.inspect}"
        assert_equal "validation_failed", JSON.parse(response.body).fetch("error")
        assert_equal original, @user.reload.preferences
      end
    end
  end

  test "invalid payload returns 422 without partial storage" do
    original = @user.preferences.deep_dup

    post "/dashboard/pages", params: {}, as: :json
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences

    post "/dashboard/pages/home/widgets", params: { widget: { key: "investments.options_mutation" } }, as: :json

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body).fetch("error")
    assert_equal original, @user.reload.preferences

    home_balance_id = @user.dashboard_pages.find { |page| page["id"] == "home" }.fetch("widgets").find { |widget| widget["key"] == "home.balance_sheet" }.fetch("id")
    patch page_widget_path("home", home_balance_id), params: { widget: { collapsed: "sometimes", layout: { col_width: 99 } } }, as: :json
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences
  end

  test "requests only mutate the current signed-in user" do
    other = users(:family_member)
    other_original = other.preferences.deep_dup

    post "/dashboard/pages", params: { page: { name: "Mine" } }, as: :json

    assert_response :created
    assert_equal other_original, other.reload.preferences
  end

  test "member without investment access cannot select investment page or add investment widget" do
    reset!
    member = users(:empty)
    member.update!(preferences: {})
    sign_in member

    patch "/dashboard/pages/current", params: { page_id: "investments" }, as: :json
    assert_response :unprocessable_entity

    post "/dashboard/pages/home/widgets", params: { widget: { key: "investments.decision_pulse" } }, as: :json
    assert_response :unprocessable_entity

    get root_path(page: "investments")
    assert_response :success
    assert_no_match I18n.t("investment_decision_center.title"), response.body
    assert_nil member.reload.preferences["dashboard_current_page"]
    assert_select "[data-testid=dashboard-page-tabs] [data-dashboard-page-key=investments]", count: 0
    assert_select "[data-testid=dashboard-widget-catalog] [data-widget-key^='investments.']", count: 0
  end

  test "page resolver handles aliases and prefetch without persistence" do
    original = @user.preferences.deep_dup

    get root_path(page: "decision"), headers: { "Sec-Purpose" => "prefetch" }

    assert_response :success
    assert_match I18n.t("investment_decision_center.title"), response.body
    assert_equal original, @user.reload.preferences
  end

  test "GET page and legacy view selectors render without changing preferences" do
    original = @user.preferences.deep_dup

    get root_path(page: "investments")
    assert_response :success
    assert_select "[data-testid=dashboard-page-tabs][data-dashboard-pages-current-page-url-value=?]", current_pages_path
    assert_select "[data-testid=dashboard-page-tabs] a[aria-current=page][data-dashboard-page-key=investments][data-action='click->dashboard-pages#selectPage']"
    assert_equal original, @user.reload.preferences

    get root_path(view: "decision")
    assert_response :success
    assert_select "turbo-frame#investment_workspace h1", text: I18n.t("investment_decision_center.title")
    assert_select "turbo-frame#investment_workspace a[href=?]", root_path(page: "investments"), text: I18n.t("investments.back_to_dashboard")
    assert_equal original, @user.reload.preferences

    get root_path(view: "overview")
    assert_response :success
    assert_select "[data-testid=dashboard-page-tabs] a[aria-current=page][data-dashboard-page-key=home]"
    assert_equal original, @user.reload.preferences
  end

  test "the current page endpoint explicitly persists selection" do
    original = @user.preferences.deep_dup

    patch current_pages_path, params: { page_id: "investments" }, as: :json

    assert_response :success
    assert_equal "investments", JSON.parse(response.body).fetch("current_page")
    assert_equal "investments", @user.reload.preferences.fetch("dashboard_current_page")
    assert_not_equal original, @user.preferences
  end

  test "unknown page falls back to Home without persistence" do
    get root_path(page: "deleted-page")

    assert_response :success
    assert_no_match I18n.t("investment_decision_center.title"), response.body
    assert_not @user.reload.preferences.key?("dashboard_pages")
    assert_nil @user.preferences["dashboard_current_page"]
  end

  test "homepage renders selected page tabs and page-specific widget controls" do
    get root_path

    assert_response :success
    assert_select "[data-testid=dashboard-page-tabs] a[aria-current=page][data-dashboard-page-key=home]", text: "Home"
    assert_select "[data-testid=dashboard-page-tabs] a[href=?]", root_path(page: "investments"), text: "Investments"
    assert_select "[data-testid=dashboard-widget-catalog] [data-widget-key='investments.income_performance']"
    assert_select "[data-dashboard-sortable-url-value=?]", order_page_widgets_path("home")
    assert_select "section[data-widget-key]" do |sections|
      sections.each do |section|
        instance_id = section["data-widget-instance-id"]
        assert_equal page_widget_path("home", instance_id), section["data-dashboard-section-url-value"]
        assert_select section, "button[data-url=?][aria-label]", page_widget_path("home", instance_id), minimum: 1
      end
    end

    get root_path(page: "investments")

    assert_response :success
    assert_select "[data-testid=dashboard-page-tabs] a[aria-current=page][data-dashboard-page-key=investments]", text: "Investments"
    assert_select "h1", text: I18n.t("investment_decision_center.title")
    assert_select "nav[aria-label=?]", I18n.t("investments.subnav.label"), count: 0
    assert_select "section[data-widget-key^='investments.']", minimum: 1
  end

  test "all supported widgets can be added and removed independently" do
    page = @user.create_dashboard_page!("Everything")

    Dashboard::WidgetRegistry.keys.each do |key|
      post page_widgets_path(page.fetch("id")), params: { widget: { key: key } }, as: :json
      assert_response :created, "expected #{key} to be addable"
      widget = response.parsed_body.fetch("widget")
      assert_equal key, widget.fetch("key")

      delete page_widget_path(page.fetch("id"), widget.fetch("id")), as: :json
      assert_response :no_content, "expected #{key} to be removable"
    end
    assert_empty @user.reload.dashboard_pages.find { |item| item["id"] == page.fetch("id") }.fetch("widgets")
  end

  test "two pages render independent widget order collapse size and unique ids" do
    first = @user.create_dashboard_page!("First")
    second = @user.create_dashboard_page!("Second")
    first_widgets = %w[home.spending_trend home.balance_sheet].map { |key| @user.add_dashboard_widget!(first.fetch("id"), key) }
    second_widgets = %w[home.balance_sheet home.spending_trend].map { |key| @user.add_dashboard_widget!(second.fetch("id"), key) }
    spending = first_widgets.find { |widget| widget["key"] == "home.spending_trend" }
    @user.update_dashboard_widget!(first.fetch("id"), spending.fetch("id"), collapsed: true, layout: { "col_width" => 12, "height" => 6 })

    get root_path(page: first.fetch("id"))

    assert_response :success
    assert_equal %w[home.spending_trend home.balance_sheet], css_select("section[data-widget-key]").map { |node| node["data-widget-key"] }
    assert_select "section[data-widget-key='home.spending_trend'][data-dashboard-section-collapsed-value=true][style*='416px']"
    assert_select "#widget-#{spending.fetch("id")}"
    ids = css_select("#dashboard_sections [id]").map { |node| node["id"] }
    assert_equal ids.uniq, ids

    get root_path(page: second.fetch("id"))

    assert_response :success
    assert_equal %w[home.balance_sheet home.spending_trend], css_select("section[data-widget-key]").map { |node| node["data-widget-key"] }
    assert_select "section[data-widget-key='home.spending_trend'][data-dashboard-section-collapsed-value=false][style*='288px']"
    second_spending = second_widgets.find { |widget| widget["key"] == "home.spending_trend" }
    assert_select "#widget-#{second_spending.fetch("id")}"
  end

  test "page management exposes only actions accepted for each page" do
    custom = @user.create_dashboard_page!("Planning")
    get root_path(page: custom.fetch("id"))

    assert_response :success
    assert_select "[data-testid=dashboard-page-list] [data-page-id=home]" do |row|
      assert_select row, "form", count: 0
      assert_select row, "button[data-action*='deletePage']", count: 0
      assert_select row, "button[data-action*='movePageUp']", count: 0
      assert_select row, "button[data-action*='movePageDown']", count: 0
    end
    assert_select "[data-testid=dashboard-page-list] [data-page-id=investments] button[data-action*='deletePage'][data-url=?]", page_path("investments")
    assert_select "[data-testid=dashboard-page-list] [data-page-id=?] form[data-action*='renamePage'][data-url=?]", custom.fetch("id"), page_path(custom.fetch("id"))
    assert_select "button[class*='h-11'][aria-label]", minimum: 1
  end

  test "an empty custom page skips dashboard data loaders and shows a functional empty state" do
    custom = @user.create_dashboard_page!("Blank")
    IncomeStatement.expects(:new).never
    InvestmentDecisionCenter.expects(:new).never

    get root_path(page: custom.fetch("id"))

    assert_response :success
    assert_select "[data-testid=dashboard-empty-page]"
    assert_select "[data-testid=dashboard-empty-page] button[data-action='click->expandable#open']"
    assert_select "[data-testid=dashboard-empty-page] [data-testid=dashboard-add-widget-dialog]"
  end

  test "investment allocation and income widgets render real scoped loaders" do
    custom = @user.create_dashboard_page!("Portfolio")
    keys = %w[
      investments.holdings investments.income_performance
    ]
    keys.each { |key| @user.add_dashboard_widget!(custom.fetch("id"), key) }

    get root_path(page: custom.fetch("id"))

    assert_response :success
    assert_equal keys, css_select("section[data-widget-key]").map { |node| node["data-widget-key"] }
    assert_select "[data-testid=holdings-widget]"
    assert_select "[data-testid=income-performance-widget]"
    assert_no_match(/options mutation/i, response.body)
  end

  test "page creation applies a template atomically and rejects inaccessible or unknown templates" do
    post pages_path, params: { page: { name: "Tax desk", template: "tax_review" } }, as: :json

    assert_response :created
    page = JSON.parse(response.body).fetch("page")
    assert_equal Dashboard::PageTemplateRegistry.fetch("tax_review").widget_keys, page.fetch("widgets").map { |widget| widget.fetch("key") }

    original = @user.reload.preferences.deep_dup
    post pages_path, params: { page: { name: "Broken", template: "not-a-template" } }, as: :json
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences

    reset!
    member = users(:empty)
    member.update!(preferences: {})
    sign_in member
    original = member.preferences.deep_dup
    post pages_path, params: { page: { name: "Private", template: "investment_focus" } }, as: :json
    assert_response :unprocessable_entity
    assert_equal original, member.reload.preferences
  end

  test "all eight investment workflow widgets expose an explicit workspace action and unique ids" do
    SnaptradeAccount.stubs(:linked_to).returns([])
    page = @user.create_dashboard_page!("Investment workflows", template_key: "blank")
    Dashboard::WidgetRegistry.investment_keys.each { |key| @user.add_dashboard_widget!(page.fetch("id"), key) }

    get root_path(page: page.fetch("id"))

    assert_response :success
    assert_equal Dashboard::WidgetRegistry.investment_keys, css_select("section[data-widget-key]").map { |node| node["data-widget-key"] }
    assert_select "[data-testid=open-investment-workspace]", count: 8
    ids = css_select("#dashboard_sections [id]").map { |node| node["id"] }
    assert_equal ids.uniq, ids
  end

  test "requires authentication" do
    reset!
    get "/dashboard/pages", as: :json

    assert_redirected_to new_session_path
  end
end
