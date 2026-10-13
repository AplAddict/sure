require "test_helper"

# Investments is a first-class destination in the main navigation, and the
# canonical news feed is one of the workspace's pages rather than a page of its
# own outside it.
class InvestmentsNavigationTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    ensure_tailwind_build
    @owner = users(:family_admin)
    @owner.family.accounts.create!(name: "Nav Brokerage", balance: 1000, cash_balance: 0, currency: "USD", owner: @owner,
                                   status: "active", accountable: Investment.new(subtype: "brokerage"))
    sign_in @owner
  end

  # The nav entry targets GET /investments (named investments_overview) once
  # that route exists and the legacy /?view=decision lens until then, so the
  # entry is useful today and needs no view change when the route lands.
  def investments_entry_path
    respond_to?(:investments_overview_path) ? investments_overview_path : root_path(view: "decision")
  end

  # Investments is a page inside Home, so the phone and tablet bottom bars have no
  # separate Investments entry and keep Home as the single current destination.
  def assert_bottom_navs_keep_investments_inside_home
    %w[mobile-bottom-nav-items tablet-bottom-nav-items].each do |list|
      assert_select "[data-testid=#{list}] a[href=?]", investments_entry_path, count: 0
      assert_select "[data-testid=#{list}] a[aria-current=page]", count: 1 do |links|
        assert_equal root_path, links.first["href"]
      end
    end
  end

  test "the main navigation offers Investments and marks it current across the workspace" do
    [ portfolio_holdings_path, tax_lot_review_path, research_news_path, market_events_path ].each do |path|
      get path

      assert_response :success, path
      assert_select "div.hidden.lg\\:block nav a[href=?][aria-current=page]", investments_entry_path, text: /Investments/, minimum: 1
      assert_select "div.hidden.lg\\:block nav a[href=?][aria-current=page]", root_path, count: 0
      assert_bottom_navs_keep_investments_inside_home
    end
  end

  test "Home and Investments are never both current" do
    get root_path(view: "decision")
    assert_response :success
    assert_select "div.hidden.lg\\:block nav a[href=?][aria-current=page]", investments_entry_path, minimum: 1
    assert_select "div.hidden.lg\\:block nav a[href=?][aria-current=page]", root_path, count: 0
    assert_bottom_navs_keep_investments_inside_home

    get root_path(view: "overview")
    assert_response :success
    assert_select "div.hidden.lg\\:block nav a[href=?][aria-current=page]", root_path, minimum: 1
    assert_select "div.hidden.lg\\:block nav a[href=?][aria-current=page]", investments_entry_path, count: 0

    get transactions_path
    assert_select "a[href=?][aria-current=page]", investments_entry_path, count: 0
  end

  test "a member without an investment account is not offered the entry" do
    sign_in users(:empty).tap { |u| u.update!(onboarded_at: 1.day.ago) }

    get transactions_path

    assert_response :success
    assert_select "a", text: /^Investments$/, count: 0
  end

  test "the legacy ?view=decision homepage keeps working" do
    get root_path(view: "decision")

    assert_response :success
    assert_select "turbo-frame#investment_workspace h1", text: I18n.t("investment_decision_center.title")
  end

  test "the news page is the single canonical feed and has a Back to Investments control" do
    get research_news_path

    assert_response :success
    assert_select "h1", count: 1
    assert_select "turbo-frame#investment_workspace[target=_top]" do
      assert_select "h1", text: I18n.t("research.news.title"), count: 1
      assert_select "nav[aria-label=?]", I18n.t("investments.subnav.label"), count: 0
      assert_select "a[href=?]", root_path(page: "investments"), text: I18n.t("investments.back_to_dashboard"), count: 1
      assert_select "form.grid"
    end
  end

  test "the news page carries the Jev sentiment filter so it stays the one sentiment-rich feed" do
    get research_news_path

    assert_response :success
    assert_select "turbo-frame#investment_workspace select[name=sentiment]"
  end

  test "legacy harvest and news links still redirect into the workspace" do
    get tax_loss_harvest_path
    assert_redirected_to tax_lot_review_path(tab: "harvest")

    get investment_news_path
    assert_redirected_to research_news_path
  end
end
