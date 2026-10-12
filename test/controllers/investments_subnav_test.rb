require "test_helper"

class InvestmentsSubnavTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    ensure_tailwind_build
    @owner = users(:family_admin)
    @owner.family.accounts.create!(name: "Subnav Brokerage", balance: 1000, cash_balance: 0, currency: "USD", owner: @owner,
                                   status: "active", accountable: Investment.new(subtype: "brokerage"))
    sign_in @owner
  end

  {
    portfolio_holdings: :holdings, investment_income: :income, tax_lot_review: :tax_lots,
    options_review: :options, market_events: :events, research_watchlist_entries: :watchlist
  }.each do |route, key|
    test "#{route} shows the investments sub-navigation with itself marked current" do
      get public_send("#{route}_path")

      assert_response :success
      assert_select "nav[aria-label=?]", I18n.t("investments.subnav.label") do
        assert_select "a[aria-current=page]", text: I18n.t("investments.subnav.#{key}")
        assert_select "a", minimum: 7
      end
    end
  end

  # Tab links swap the investment_workspace frame, so every page must render
  # its heading and the sub-navigation inside that frame: anything outside it
  # would stay on screen, stale, after a tab click (the previous page's title
  # above the new page's content, and two tab strips marking different tabs).
  %w[portfolio_holdings investment_income tax_lot_review options_review market_events research_watchlist_entries investment_news].each do |route|
    test "#{route} renders its single heading and sub-navigation inside the workspace frame" do
      get public_send("#{route}_path")

      assert_response :success
      assert_select "h1", count: 1
      assert_select "nav[aria-label=?]", I18n.t("investments.subnav.label"), count: 1
      # Links out of the workspace (ticker research, account pages) go to
      # pages without this frame, so the frame targets _top by default and
      # only the tab strip opts back into the frame.
      assert_select "turbo-frame#investment_workspace[target=_top]" do
        assert_select "h1", count: 1
        assert_select "nav[aria-label=?]", I18n.t("investments.subnav.label"), count: 1
      end
    end
  end

  test "decision center renders its heading inside the workspace frame" do
    get root_path(view: "decision")

    assert_response :success
    assert_select "h1", count: 1
    assert_select "turbo-frame#investment_workspace h1", text: I18n.t("investment_decision_center.title")
  end

  test "an in-frame tab load carries exactly one heading and sub-navigation" do
    get portfolio_holdings_path, headers: { "Turbo-Frame" => "investment_workspace" }

    assert_response :success
    assert_select "turbo-frame#investment_workspace" do
      assert_select "h1", count: 1
      assert_select "nav[aria-label=?]", I18n.t("investments.subnav.label"), count: 1
    end
  end
end
