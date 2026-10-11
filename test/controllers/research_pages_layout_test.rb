require "test_helper"

# The research pages sit between the account sidebar and the chat panel, so the
# room they get depends on the panels, not the screen. Their grids therefore use
# container queries (@container) instead of viewport breakpoints; this keeps that
# from regressing to lg:/xl: breakpoints that squeeze cards into ~260px columns.
class ResearchPagesLayoutTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    ensure_tailwind_build
    sign_in users(:family_admin)
  end

  test "search page lays out by container width" do
    get research_search_path(q: "")

    assert_response :success
    assert_select ".\\@container .grid.\\@3xl\\:grid-cols-2"
    assert_select ".lg\\:grid-cols-2", count: 0
  end

  test "news page filters lay out by container width" do
    get research_news_path

    assert_response :success
    assert_select "form.grid.\\@md\\:grid-cols-2"
  end

  test "ticker page grids lay out by container width and cards may shrink" do
    ticker = users(:family_admin).accessible_accounts.flat_map { |a| a.current_holdings.map { |h| h.security.ticker } }.first
    skip "no held security in fixtures" unless ticker

    get research_ticker_path(ticker)

    assert_response :success
    assert_select ".\\@container .\\@4xl\\:grid-cols-2"
    assert_select ".xl\\:grid-cols-2", count: 0
    assert_select "section.min-w-0", minimum: 5
  end
end
