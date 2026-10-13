require "test_helper"

class InvestmentsSubnavTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    ensure_tailwind_build
    @owner = users(:family_admin)
    @owner.family.accounts.create!(name: "Workspace Brokerage", balance: 1000, cash_balance: 0, currency: "USD", owner: @owner,
                                   status: "active", accountable: Investment.new(subtype: "brokerage"))
    sign_in @owner
  end

  %w[portfolio_holdings investment_income tax_lot_review options_review market_events research_watchlist_entries research_news].each do |route|
    test "#{route} renders one workspace heading and Back to Investments without the old sub-navigation" do
      get public_send("#{route}_path")

      assert_response :success
      assert_select "h1", count: 1
      assert_select "nav[aria-label=?]", I18n.t("investments.subnav.label"), count: 0
      assert_select "turbo-frame#investment_workspace[target=_top]" do
        assert_select "h1", count: 1
        assert_select "a[href=?]", root_path(page: "investments"), text: I18n.t("investments.back_to_dashboard"), count: 1
      end
    end
  end

  test "decision workspace has one Back to Investments control and no sub-navigation" do
    get root_path(view: "decision")

    assert_response :success
    assert_select "turbo-frame#investment_workspace" do
      assert_select "h1", text: I18n.t("investment_decision_center.title"), count: 1
      assert_select "a[href=?]", root_path(page: "investments"), text: I18n.t("investments.back_to_dashboard"), count: 1
      assert_select "nav[aria-label=?]", I18n.t("investments.subnav.label"), count: 0
    end
  end

  test "in-frame workspace load still carries its heading and back control" do
    get portfolio_holdings_path, headers: { "Turbo-Frame" => "investment_workspace" }

    assert_response :success
    assert_select "turbo-frame#investment_workspace" do
      assert_select "h1", count: 1
      assert_select "a[href=?]", root_path(page: "investments"), count: 1
    end
  end
end
