require "test_helper"

class SidebarHoldingsTabTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    ensure_tailwind_build
    @owner = users(:family_admin)
    @member = users(:family_member)

    @private = @owner.family.accounts.create!(
      name: "Owner Private Brokerage", balance: 5_000, cash_balance: 0, currency: "USD", owner: @owner,
      status: "active", accountable: Investment.new(subtype: "brokerage")
    )
    @sec = Security.create!(ticker: "SBHLD", exchange_mic: "XNAS", name: "Sidebar Holding Co")
    @private.holdings.create!(security: @sec, date: Date.current, qty: 5, price: 100, amount: 500, currency: "USD", cost_basis: 90, cost_basis_source: "provider")
  end

  test "the owner gets a Holdings tab listing their accounts with positions" do
    sign_in @owner
    get root_path

    assert_response :success
    assert_select "[data-testid=sidebar-holdings]", minimum: 1
    assert_select "[data-testid=sidebar-holdings]", text: /Owner Private Brokerage/
    assert_select "[data-testid=sidebar-holdings] a[href=?]", research_ticker_path("SBHLD")
    assert_select "[data-testid=sidebar-holdings] a[href=?]", portfolio_holdings_path
  end

  test "another member of the family never sees the owner's private account in the tab" do
    sign_in @member
    get root_path

    assert_response :success
    assert_no_match(/Owner Private Brokerage/, response.body)
    assert_no_match(/SBHLD/, response.body)
  end

  test "a member with no investment accounts gets no Holdings tab" do
    sign_in users(:empty)
    get root_path

    assert_response :success
    assert_select "[data-testid=sidebar-holdings]", count: 0
  end

  test "the holdings tab can be the remembered sidebar tab" do
    sign_in @owner
    get root_path(account_sidebar_tab: "holdings")

    assert_response :success
    assert_select "[data-testid=sidebar-holdings]"
  end

  test "an unknown sidebar tab value is ignored" do
    sign_in @owner
    get root_path(account_sidebar_tab: "bogus")

    assert_response :success
  end

  test "sidebar holdings disclosure renders every accessible position, not a 15-position preview" do
    16.times do |index|
      security = Security.create!(ticker: "SB#{index.to_s.rjust(3, '0')}", exchange_mic: "XNAS", name: "Sidebar #{index}")
      @private.holdings.create!(security: security, date: Date.current, qty: 1, price: index + 1, amount: index + 1, currency: "USD")
    end

    sign_in @owner
    get root_path(account_sidebar_tab: "holdings")

    assert_response :success
    assert_select "[data-testid=sidebar-holding-position]", minimum: 17
  end

  test "sidebar holdings offers metric selection and supplies color-coded change values" do
    sign_in @owner
    get root_path(account_sidebar_tab: "holdings")

    assert_response :success
    assert_select "[data-testid=sidebar-holdings][data-controller~=sidebar-holding-metric]"
    assert_select "[data-testid=sidebar-holdings] select[data-sidebar-holding-metric-target=selector] option[value=price]"
    assert_select "[data-testid=sidebar-holdings] select[data-sidebar-holding-metric-target=selector] option[value=day_gain_pct]"
    assert_select "[data-testid=sidebar-holdings] [data-sidebar-holding-metric-target=value][data-sidebar-holding-metric-values]"
  end

  test "sidebar summary lists positions largest first with weights that sum to 100" do
    other = Security.create!(ticker: "SBSML", exchange_mic: "XNAS", name: "Small")
    @private.holdings.create!(security: other, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD")

    entry = PortfolioHoldings.new(user: @owner).sidebar_accounts.find { |e| e.account.id == @private.id }

    assert_equal %w[SBHLD SBSML], entry.positions.map(&:ticker)
    assert_in_delta 100, entry.positions.sum(&:weight), 0.001
  end
end
