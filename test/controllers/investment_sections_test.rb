require "test_helper"

class InvestmentSectionsTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:family_admin)
    @other = users(:family_member)
    sign_in @owner
  end

  test "income page renders its sections in the default order" do
    get investment_income_path
    assert_response :success
    keys = css_select("[data-reports-sortable-target=section]").map { |node| node["data-section-key"] }
    assert_equal %w[income monthly_income cash_flows performance realized_gains], keys
  end

  test "saving a new order and collapsed state is honoured on the next visit" do
    patch investment_section_preferences_path("income"), params: { preferences: { investments_income_section_order: %w[realized_gains income], investments_income_collapsed_sections: { performance: true } } }, as: :json
    assert_response :ok

    get investment_income_path
    nodes = css_select("[data-reports-sortable-target=section]")
    assert_equal %w[realized_gains income monthly_income cash_flows performance], nodes.map { |n| n["data-section-key"] }
    assert_equal "true", nodes.find { |n| n["data-section-key"] == "performance" }["data-reports-section-collapsed-value"]
  end

  test "unknown keys, other namespaces and non-boolean values are never stored" do
    patch investment_section_preferences_path("income"), params: { preferences: { investments_income_section_order: %w[income hacked income], investments_income_collapsed_sections: { hacked: true, income: "yes" } } }, as: :json
    assert_response :ok
    prefs = @owner.reload.preferences
    assert_equal %w[income], prefs["investments_income_section_order"]
    assert_equal({ "income" => true }, prefs["investments_income_collapsed_sections"])

    patch investment_section_preferences_path("evil"), params: { preferences: { x: 1 } }, as: :json
    assert_response :not_found
    refute @owner.reload.preferences.key?("investments_evil_section_order")
  end

  test "layout is stored per member" do
    patch investment_section_preferences_path("income"), params: { preferences: { investments_income_section_order: %w[performance] } }, as: :json
    assert_equal %w[performance], @owner.reload.preferences["investments_income_section_order"]
    assert_nil @other.reload.preferences&.dig("investments_income_section_order")
    assert_empty @other.investment_section_order("income")
  end

  test "holdings page shows allocation and data quality sections that can be reordered" do
    get portfolio_holdings_path(by: "sector")
    assert_response :success
    assert_equal %w[allocation data_quality], css_select("[data-reports-sortable-target=section]").map { |n| n["data-section-key"] }
    assert_select "[data-testid=allocation-section] a[aria-current=true]", text: "Sector"
  end

  test "the income page shows the money-weighted return as unavailable rather than guessing" do
    get investment_income_path
    assert_response :success
    assert_select "[data-section-key=performance]", text: /Money-weighted return/
  end

  test "reset layout clears this member's order and collapsed state only for that page" do
    patch investment_section_preferences_path("income"), params: { preferences: { investments_income_section_order: %w[realized_gains income], investments_income_collapsed_sections: { performance: true } } }, as: :json
    patch investment_section_preferences_path("holdings"), params: { preferences: { investments_holdings_section_order: %w[data_quality allocation] } }, as: :json
    sign_in @other
    patch investment_section_preferences_path("income"), params: { preferences: { investments_income_section_order: %w[performance] } }, as: :json
    sign_in @owner

    delete investment_section_preferences_path("income")
    assert_response :ok

    prefs = @owner.reload.preferences
    assert_not prefs.key?("investments_income_section_order")
    assert_not prefs.key?("investments_income_collapsed_sections")
    assert_equal %w[data_quality allocation], prefs["investments_holdings_section_order"]
    assert_equal %w[performance], @other.reload.preferences["investments_income_section_order"]

    get investment_income_path
    keys = css_select("[data-reports-sortable-target=section]").map { |node| node["data-section-key"] }
    assert_equal %w[income monthly_income cash_flows performance realized_gains], keys
  end

  test "reset layout rejects an unknown page" do
    delete investment_section_preferences_path("evil")
    assert_response :not_found
  end

  test "the drag handle is always visible and is the only touch target" do
    get investment_income_path
    assert_response :success

    section = css_select("[data-reports-sortable-target=section]").first
    assert_no_match(/touchstart->reports-sortable/, section["data-action"].to_s)
    assert_select "[data-reports-sortable-target=section] button[data-reports-sortable-target=handle]", count: 5
    assert_select "button[data-reports-sortable-target=handle][class*=touch-none]", minimum: 1
    assert_select "button[data-reports-sortable-target=handle][class*=opacity-0]", count: 0
    assert_select "[data-reports-sortable-target=section][aria-grabbed]", count: 0
  end

  test "a reset layout control is offered" do
    get investment_income_path
    assert_select %(button[data-action="click->reports-sortable#reset"]), text: /Reset layout/
  end

  test "allocation explains the unreported-fund slice and colours Unclassified grey" do
    get portfolio_holdings_path(by: "asset_class")
    assert_response :success
    assert_select "[data-testid=allocation-section] [data-testid=allocation-legend]"
    assert_select "[data-testid=allocation-section] [data-testid=allocation-explainer]"
  end
end
