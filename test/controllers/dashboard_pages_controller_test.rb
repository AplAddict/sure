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

    post "/dashboard/pages/#{page_id}/widgets", params: { widget: { key: "home.balance_sheet" } }, as: :json
    assert_response :created

    patch "/dashboard/pages/#{page_id}/widgets/home.spending_trend", params: { widget: { collapsed: true, layout: { col_width: 12, height: 6 } } }, as: :json
    assert_response :success
    widget = JSON.parse(response.body).fetch("widget")
    assert widget.fetch("collapsed")
    assert_equal({ "col_width" => 12, "height" => 6 }, widget.fetch("layout"))

    patch "/dashboard/pages/#{page_id}/widgets/order", params: { widget_keys: %w[home.balance_sheet home.spending_trend] }, as: :json
    assert_response :success
    assert_equal %w[home.balance_sheet home.spending_trend], JSON.parse(response.body).fetch("page").fetch("widgets").map { |row| row.fetch("key") }

    delete "/dashboard/pages/#{page_id}/widgets/home.spending_trend", as: :json
    assert_response :no_content
    assert_not_includes @user.reload.dashboard_pages.find { |page| page["id"] == page_id }["widgets"].map { |row| row["key"] }, "home.spending_trend"
  end

  test "invalid widget layouts and duplicate adds return 422 atomically" do
    post "/dashboard/pages", params: { page: { name: "Widgets" } }, as: :json
    page_id = JSON.parse(response.body).dig("page", "id")
    post "/dashboard/pages/#{page_id}/widgets", params: { widget: { key: "home.spending_trend" } }, as: :json
    assert_response :created
    post "/dashboard/pages/#{page_id}/widgets", params: { widget: { key: "home.outflows_donut" } }, as: :json
    assert_response :created
    original = @user.reload.preferences.deep_dup

    post "/dashboard/pages/#{page_id}/widgets", params: { widget: { key: "home.spending_trend" } }, as: :json
    assert_response :unprocessable_entity
    assert_equal "widget already exists on page", JSON.parse(response.body).fetch("message")
    assert_equal original, @user.reload.preferences

    [
      [ "home.spending_trend", { col_width: 7 } ],
      [ "home.spending_trend", { height: 5 } ],
      [ "home.spending_trend", { width: 12 } ],
      [ "home.spending_trend", "invalid" ],
      [ "home.outflows_donut", { col_width: 12 } ]
    ].each do |widget_key, layout|
      patch "/dashboard/pages/#{page_id}/widgets/#{widget_key}", params: { widget: { collapsed: true, layout: layout } }, as: :json
      assert_response :unprocessable_entity
      assert_equal original, @user.reload.preferences
    end

    patch "/dashboard/pages/#{page_id}/widgets/home.spending_trend", params: { widget: { layout: { col_width: 12, height: 6 } } }, as: :json
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

  test "invalid payload returns 422 without partial storage" do
    original = @user.preferences.deep_dup

    post "/dashboard/pages", params: {}, as: :json
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences

    post "/dashboard/pages/home/widgets", params: { widget: { key: "investments.options_mutation" } }, as: :json

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body).fetch("error")
    assert_equal original, @user.reload.preferences

    patch "/dashboard/pages/home/widgets/home.balance_sheet", params: { widget: { collapsed: "sometimes", layout: { col_width: 99 } } }, as: :json
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
  end

  test "page resolver handles aliases and prefetch without persistence" do
    get root_path(page: "decision"), headers: { "Sec-Purpose" => "prefetch" }

    assert_response :success
    assert_match I18n.t("investment_decision_center.title"), response.body
    assert_not @user.reload.preferences.key?("dashboard_pages")
    assert_nil @user.preferences["dashboard_current_page"]
  end

  test "unknown page falls back to Home without persistence" do
    get root_path(page: "deleted-page")

    assert_response :success
    assert_no_match I18n.t("investment_decision_center.title"), response.body
    assert_not @user.reload.preferences.key?("dashboard_pages")
    assert_nil @user.preferences["dashboard_current_page"]
  end

  test "requires authentication" do
    reset!
    get "/dashboard/pages", as: :json

    assert_redirected_to new_session_path
  end
end
