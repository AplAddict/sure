require "test_helper"

class UserDashboardPagesTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: {
      "section_order" => %w[balance_sheet cashflow_sankey],
      "collapsed_sections" => { "balance_sheet" => true },
      "dashboard_section_layout" => { "cashflow_sankey" => { "col_span" => "full", "height" => "tall" } },
      "investments_decision_section_order" => %w[monitor pulse actions],
      "investments_decision_collapsed_sections" => { "monitor" => true },
      "dashboard_view" => "decision"
    })
  end

  test "read-forward synthesizes pages from legacy preferences without writing" do
    pages = @user.dashboard_pages

    assert_equal %w[home investments], pages.map { |page| page["id"] }
    assert_equal %w[home.balance_sheet home.cashflow_sankey], pages.first["widgets"].first(2).map { |widget| widget["key"] }
    assert pages.first["widgets"].first["collapsed"]
    assert_equal %w[investments.decision_monitor investments.decision_pulse investments.decision_action], pages.last["widgets"].map { |widget| widget["key"] }
    assert_equal "investments", @user.dashboard_current_page
    assert_not @user.reload.preferences.key?("dashboard_pages")
  end

  test "legacy aliases resolve to system pages" do
    assert_equal "home", @user.resolve_dashboard_page_id("overview")
    assert_equal "investments", @user.resolve_dashboard_page_id("decision")
  end

  test "invalid page updates do not partially persist" do
    original = @user.preferences.deep_dup
    invalid = @user.dashboard_pages.deep_dup
    invalid.first["widgets"] << invalid.first["widgets"].first.deep_dup

    error = assert_raises(User::DashboardPagesValidationError) do
      @user.replace_dashboard_pages!(invalid, current_page: "home")
    end

    assert_match(/unique/, error.message)
    assert_equal original, @user.reload.preferences
  end

  test "custom pages get validated ids and trimmed names" do
    page = @user.create_dashboard_page!("  My page  ")

    assert_match(/\Ap_[0-9a-z]{8}\z/, page.fetch("id"))
    assert_equal "My page", page.fetch("name")
    assert_equal page.fetch("id"), @user.reload.dashboard_current_page
  end

  test "investments starts second, can be removed, and is only restored explicitly" do
    assert_equal %w[home investments], @user.dashboard_pages.map { |page| page["id"] }
    @user.add_dashboard_widget!("home", "investments.decision_pulse")

    @user.delete_dashboard_page!("investments")

    assert_equal [ "home" ], @user.reload.dashboard_pages.map { |page| page["id"] }
    assert_not @user.dashboard_pages.first["widgets"].any? { |widget| widget["key"].start_with?("investments.") }
    assert_equal "home", @user.resolve_dashboard_page_id("investments")
    assert_equal "home", @user.resolve_dashboard_page_id("decision")
    assert_raises(User::DashboardPagesValidationError) { @user.delete_dashboard_page!("home") }

    restored = @user.create_dashboard_page!(nil, page_id: "investments")

    assert_equal({ "id" => "investments", "name" => "Investments", "widgets" => restored.fetch("widgets") }, restored)
    assert_equal %w[home investments], @user.reload.dashboard_pages.map { |page| page["id"] }
  end

  test "system names ignore blank input and remain stable" do
    pages = @user.dashboard_pages.deep_dup
    pages.first["name"] = nil
    pages.second["name"] = "  "

    @user.replace_dashboard_pages!(pages, current_page: "home")

    assert_equal [ "Home", "Investments" ], @user.reload.dashboard_pages.map { |page| page["name"] }
  end

  test "widget add rejects duplicates explicitly without persisting" do
    original = @user.preferences.deep_dup

    error = assert_raises(User::DashboardPagesValidationError) do
      @user.add_dashboard_widget!("home", "home.balance_sheet")
    end

    assert_equal "widget already exists on page", error.message
    assert_equal original, @user.reload.preferences
  end

  test "page reorder requires the complete unique order with Home first" do
    custom = @user.create_dashboard_page!("Planning")
    before = @user.reload.preferences.deep_dup

    assert_raises(User::DashboardPagesValidationError) do
      @user.reorder_dashboard_pages!([ "home", custom.fetch("id") ])
    end
    assert_raises(User::DashboardPagesValidationError) do
      @user.reorder_dashboard_pages!([ "home", "investments", "investments" ])
    end
    assert_raises(User::DashboardPagesValidationError) do
      @user.reorder_dashboard_pages!([ "investments", "home", custom.fetch("id") ])
    end
    assert_equal before, @user.reload.preferences

    @user.reorder_dashboard_pages!([ "home", custom.fetch("id"), "investments" ])
    assert_equal [ "home", custom.fetch("id"), "investments" ], @user.reload.dashboard_pages.map { |page| page["id"] }
  end

  test "rejects unknown widgets, overlong names, too many pages and oversized serialization" do
    assert_raises(User::DashboardPagesValidationError) { @user.create_dashboard_page!("x" * 41) }

    page = @user.create_dashboard_page!("Valid")
    assert_raises(User::DashboardPagesValidationError) { @user.add_dashboard_widget!(page.fetch("id"), "unknown.widget") }

    5.times { |index| @user.create_dashboard_page!("Page #{index}") }
    assert_raises(User::DashboardPagesValidationError) { @user.create_dashboard_page!("Ninth") }

    pages = @user.dashboard_pages.deep_dup
    pages.last["name"] = "a" * 17_000
    assert_raises(User::DashboardPagesValidationError) { @user.replace_dashboard_pages!(pages) }
  end

  test "member without investment access cannot read investment pages or widgets" do
    user = users(:empty)
    user.update!(preferences: {
      "dashboard_pages" => [
        { "id" => "home", "name" => "Home", "widgets" => [ { "key" => "home.balance_sheet", "collapsed" => false, "layout" => { "col_width" => 6, "height" => 4 } }, { "key" => "investments.decision_pulse", "collapsed" => false, "layout" => { "col_width" => 6, "height" => 4 } } ] },
        { "id" => "investments", "name" => "Investments", "widgets" => [ { "key" => "investments.decision_pulse", "collapsed" => false, "layout" => { "col_width" => 6, "height" => 4 } } ] }
      ],
      "dashboard_current_page" => "investments"
    })

    assert_equal [ "home" ], user.dashboard_pages.map { |page| page["id"] }
    assert_equal [ "home.balance_sheet" ], user.dashboard_pages.first["widgets"].map { |widget| widget["key"] }
    assert_equal "home", user.dashboard_current_page

    custom = user.create_dashboard_page!("Safe page")
    stored_pages = user.reload.preferences.fetch("dashboard_pages")
    assert_equal [ "home", custom.fetch("id") ], stored_pages.map { |page| page["id"] }
    assert_not stored_pages.flat_map { |page| page["widgets"] }.any? { |widget| Dashboard::WidgetRegistry.fetch(widget["key"]).investment_required }
    assert_equal custom.fetch("id"), user.preferences.fetch("dashboard_current_page")
  end
end
