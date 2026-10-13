require "test_helper"

class DashboardWidgetInstancesTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: {})
    sign_in @user
    @page = @user.create_dashboard_page!("Instances")
  end

  test "same type instances keep immutable ids order and settings independently" do
    account = accounts(:investment)

    post page_widgets_path(@page.fetch("id")), params: {
      widget: { key: "portfolio.allocation", settings: { scope: "overall", account_id: nil, rows: 5, grouping: "asset_class" } }
    }, as: :json
    assert_response :created
    overall = response.parsed_body.fetch("widget")

    post page_widgets_path(@page.fetch("id")), params: {
      widget: { key: "portfolio.allocation", settings: { scope: "account", account_id: account.id, rows: 8, grouping: "sector" } }
    }, as: :json
    assert_response :created
    scoped = response.parsed_body.fetch("widget")

    assert_match User::DASHBOARD_WIDGET_INSTANCE_ID, overall.fetch("id")
    assert_match User::DASHBOARD_WIDGET_INSTANCE_ID, scoped.fetch("id")
    assert_not_equal overall.fetch("id"), scoped.fetch("id")

    patch page_widget_path(@page.fetch("id"), overall.fetch("id")), params: {
      widget: { settings: overall.fetch("settings").merge("rows" => 3) }
    }, as: :json
    assert_response :success

    patch order_page_widgets_path(@page.fetch("id")), params: { instance_ids: [ scoped.fetch("id"), overall.fetch("id") ] }, as: :json
    assert_response :success
    assert_equal [ scoped.fetch("id"), overall.fetch("id") ], response.parsed_body.dig("page", "widgets").map { |widget| widget.fetch("id") }

    delete page_widget_path(@page.fetch("id"), scoped.fetch("id")), as: :json
    assert_response :no_content
    remaining = @user.reload.dashboard_pages.find { |page| page["id"] == @page.fetch("id") }.fetch("widgets").sole
    assert_equal overall.fetch("id"), remaining.fetch("id")
    assert_equal 3, remaining.dig("settings", "rows")
    assert_equal "overall", remaining.dig("settings", "scope")
  end

  test "identical duplicate requires explicit confirmation" do
    post page_widgets_path(@page.fetch("id")), params: { widget: { key: "income.summary" } }, as: :json
    assert_response :created
    original = @user.reload.preferences.deep_dup

    post page_widgets_path(@page.fetch("id")), params: { widget: { key: "income.summary" } }, as: :json
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences

    post page_widgets_path(@page.fetch("id")), params: { widget: { key: "income.summary", allow_duplicate: true } }, as: :json
    assert_response :created

    post page_widgets_path(@page.fetch("id")), params: {
      widget: {
        key: "portfolio.allocation",
        settings: { scope: "overall", account_id: "", rows: 5, grouping: "asset_class" }
      }
    }, as: :json
    assert_response :created
    assert_nil response.parsed_body.dig("widget", "settings", "account_id")

    post page_widgets_path(@page.fetch("id")), params: {
      widget: {
        key: "portfolio.allocation",
        settings: { scope: "overall", account_id: nil, rows: 5, grouping: "asset_class" }
      }
    }, as: :json
    assert_response :unprocessable_entity
  end

  test "security instances for AAPL and MSFT render without DOM collisions" do
    Holding.create!(
      account: accounts(:investment), security: securities(:msft), date: Date.current,
      qty: 2, price: 410, amount: 820, currency: "USD"
    )

    [ securities(:aapl), securities(:msft) ].each do |security|
      post page_widgets_path(@page.fetch("id")), params: {
        widget: { key: "portfolio.security_snapshot", settings: { scope: "security", security_id: security.id } }
      }, as: :json
      assert_response :created
    end

    get root_path(page: @page.fetch("id"))
    assert_response :success
    sections = css_select("section[data-widget-key='portfolio.security_snapshot']")
    assert_equal 2, sections.size
    assert_equal 2, sections.map { |section| section["data-widget-instance-id"] }.uniq.size
    ids = css_select("#dashboard_sections [id]").map { |node| node["id"] }
    assert_equal ids.uniq, ids
    assert_match(/AAPL/, response.body)
    assert_match(/MSFT/, response.body)
  end

  test "overall and account instances render independently without account leakage" do
    Holding.create!(
      account: accounts(:crypto), security: securities(:msft), date: Date.current,
      qty: 2, price: 410, amount: 820, currency: "USD"
    )
    overall = @user.add_dashboard_widget!(
      @page.fetch("id"), "portfolio.allocation",
      settings: { scope: "overall", account_id: nil, rows: 5, grouping: "security" }
    )
    scoped = @user.add_dashboard_widget!(
      @page.fetch("id"), "portfolio.allocation",
      settings: { scope: "account", account_id: accounts(:investment).id, rows: 5, grouping: "security" }
    )

    get root_path(page: @page.fetch("id"))

    assert_response :success
    overall_section = css_select("section[data-widget-instance-id='#{overall.fetch("id")}']").sole
    scoped_section = css_select("section[data-widget-instance-id='#{scoped.fetch("id")}']").sole
    assert_includes overall_section.text, "AAPL"
    assert_includes overall_section.text, "MSFT"
    assert_includes scoped_section.text, "AAPL"
    assert_not_includes scoped_section.text, "MSFT"
    assert_includes scoped_section.text, accounts(:investment).name
  end

  test "duplicate chart widgets use instance ids for every rendered DOM id" do
    first = @user.add_dashboard_widget!(@page.fetch("id"), "home.net_worth_chart")
    second = @user.add_dashboard_widget!(@page.fetch("id"), "home.net_worth_chart", allow_duplicate: true)

    get root_path(page: @page.fetch("id"))

    assert_response :success
    ids = css_select("#dashboard_sections [id]").map { |node| node["id"] }
    assert_equal ids.uniq, ids
    assert_select "#widget-#{first.fetch("id")}-chart", count: 1
    assert_select "#widget-#{second.fetch("id")}-chart", count: 1
  end

  test "unknown malformed and inaccessible settings are atomic" do
    widget = @user.add_dashboard_widget!(@page.fetch("id"), "portfolio.allocation")
    original = @user.reload.preferences.deep_dup
    inaccessible_account = accounts(:depository)

    invalid_settings = [
      widget.fetch("settings").merge("unknown" => true),
      widget.fetch("settings").merge("rows" => "5"),
      widget.fetch("settings").merge("scope" => "account", "account_id" => inaccessible_account.id),
      widget.fetch("settings").merge("scope" => "account", "account_id" => "not-an-id"),
      widget.fetch("settings").merge("scope" => "account", "account_id" => inaccessible_account.id, "security_id" => "extra")
    ]

    invalid_settings.each do |settings|
      patch page_widget_path(@page.fetch("id"), widget.fetch("id")), params: { widget: { settings: settings } }, as: :json
      assert_response :unprocessable_entity
      assert_equal original, @user.reload.preferences
    end
  end

  test "inaccessible security is rejected without exposing another symbol" do
    original = @user.reload.preferences.deep_dup

    post page_widgets_path(@page.fetch("id")), params: {
      widget: { key: "portfolio.security_snapshot", settings: { scope: "security", security_id: securities(:msft).id } }
    }, as: :json

    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences
  end

  test "account portfolio review applies editable account scope atomically" do
    account = accounts(:investment)

    post pages_path, params: { page: { name: "Account Review", template: "account_portfolio_review", account_id: account.id } }, as: :json

    assert_response :created
    page = response.parsed_body.fetch("page")
    scoped = page.fetch("widgets").select do |widget|
      Dashboard::WidgetRegistry.fetch(widget.fetch("key")).settings.key?("account_id")
    end
    assert scoped.any?
    assert scoped.all? { |widget| widget.dig("settings", "scope") == "account" && widget.dig("settings", "account_id") == account.id }
    assert_equal page.fetch("widgets").size, page.fetch("widgets").map { |widget| widget.fetch("id") }.uniq.size

    original = @user.reload.preferences.deep_dup
    post pages_path, params: { page: { name: "Wrong account", template: "account_portfolio_review", account_id: accounts(:depository).id } }, as: :json
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences
  end

  test "legacy preferences read forward with stable instance ids" do
    @user.update!(preferences: {
      "dashboard_pages" => [
        {
          "id" => "home", "name" => "Home",
          "widgets" => [ { "key" => "home.balance_sheet", "collapsed" => false, "layout" => { "col_width" => 6, "height" => 4 } } ]
        }
      ],
      "dashboard_current_page" => "home"
    })

    first = @user.dashboard_pages.dig(0, "widgets", 0)
    second = @user.dashboard_pages.dig(0, "widgets", 0)

    assert_match User::DASHBOARD_WIDGET_INSTANCE_ID, first.fetch("id")
    assert_equal first.fetch("id"), second.fetch("id")
    assert_equal Dashboard::WidgetRegistry.fetch("home.balance_sheet").default_settings, first.fetch("settings")
    assert_not @user.reload.preferences.dig("dashboard_pages", 0, "widgets", 0).key?("id")
  end
end
