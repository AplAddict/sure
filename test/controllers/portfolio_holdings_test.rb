require "test_helper"

class PortfolioHoldingsTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    ensure_tailwind_build
    @owner = users(:family_admin)
    @member = users(:family_member)
    @family = @owner.family

    @account = @family.accounts.create!(
      name: "Holdings Brokerage", balance: 10_000, cash_balance: 500, currency: "USD", owner: @owner,
      status: "active", accountable: Investment.new(subtype: "brokerage")
    )
    @big = Security.create!(ticker: "PHBIG", exchange_mic: "XNAS", name: "Big Winner")
    @small = Security.create!(ticker: "PHSML", exchange_mic: "XNAS", name: "Small Loser")
    @nocb = Security.create!(ticker: "PHNCB", exchange_mic: "XNAS", name: "No Basis")

    @account.holdings.create!(security: @big, date: Date.current, qty: 10, price: 200, amount: 2000, currency: "USD", cost_basis: 100, cost_basis_source: "provider")
    @account.holdings.create!(security: @small, date: Date.current, qty: 10, price: 50, amount: 500, currency: "USD", cost_basis: 80, cost_basis_source: "provider")
    @account.holdings.create!(security: @nocb, date: Date.current, qty: 4, price: 25, amount: 100, currency: "USD")
  end

  def positions(sort: nil, direction: nil, user: @owner)
    block = PortfolioHoldings.new(user: user, account_id: @account.id, sort: sort, direction: direction).blocks.find { |b| b.account.id == @account.id }
    block&.positions&.map(&:ticker)
  end

  # ---- model ----

  test "lists each position with gain computed from known basis" do
    block = PortfolioHoldings.new(user: @owner, account_id: @account.id).blocks.first
    big = block.positions.find { |p| p.ticker == "PHBIG" }

    assert_equal BigDecimal("1000"), big.cost_basis
    assert_equal BigDecimal("1000"), big.gain
    assert_equal BigDecimal("100"), big.gain_pct
  end

  test "a position without cost basis has no gain, never zero, and does not count toward the account gain" do
    block = PortfolioHoldings.new(user: @owner, account_id: @account.id).blocks.first
    nocb = block.positions.find { |p| p.ticker == "PHNCB" }

    assert_nil nocb.cost_basis
    assert_nil nocb.gain
    assert_not block.complete_basis?
    assert_nil block.cost_basis, "an account total is withheld rather than summed over a partial set"
    assert_nil block.gain
  end

  test "sorts by any column in either direction and keeps unmeasurable rows last" do
    assert_equal %w[PHBIG PHSML PHNCB], positions(sort: "market_value")
    assert_equal %w[PHNCB PHSML PHBIG], positions(sort: "market_value", direction: "asc")
    assert_equal %w[PHBIG PHNCB PHSML], positions(sort: "symbol", direction: "asc")
    assert_equal %w[PHBIG PHSML PHNCB], positions(sort: "gain", direction: "desc")
    assert_equal %w[PHSML PHBIG PHNCB], positions(sort: "gain", direction: "asc"), "no-basis row stays last when ascending too"
  end

  test "an unknown sort or direction falls back safely" do
    portfolio = PortfolioHoldings.new(user: @owner, sort: "'; drop table holdings; --", direction: "sideways")

    assert_equal "market_value", portfolio.sort
    assert_equal "desc", portfolio.direction
    assert_nothing_raised { portfolio.blocks }
  end

  test "weights are shares of the account's own holdings and sum to 100" do
    block = PortfolioHoldings.new(user: @owner, account_id: @account.id).blocks.first

    assert_in_delta 100, block.positions.sum { |p| p.weight }, 0.001
    assert_in_delta 76.923, block.positions.find { |p| p.ticker == "PHBIG" }.weight, 0.01
  end

  test "a closed position is not listed" do
    closed = Security.create!(ticker: "PHCLS", exchange_mic: "XNAS")
    @account.holdings.create!(security: closed, date: Date.current, qty: 0, price: 10, amount: 0, currency: "USD")

    assert_not_includes positions, "PHCLS"
  end

  test "another member never sees the owner's private account" do
    @account.update!(owner: @owner)
    assert_not_includes @account.family.accounts.accessible_by(@member).pluck(:id), @account.id, "fixture precondition: account is private to its owner"

    assert_nil positions(user: @member)
    assert_not PortfolioHoldings.new(user: @member, account_id: @account.id).scope_valid?
  end

  test "an account id that is not accessible is not a valid scope" do
    assert_not PortfolioHoldings.new(user: @owner, account_id: SecureRandom.uuid).scope_valid?
  end

  # ---- lots ----

  def with_lots(symbol, units:, lots:)
    provider_account = SnaptradeAccount.new(raw_holdings_payload: { "positions" => [ { "instrument" => { "symbol" => symbol }, "units" => units, "tax_lots" => lots } ] })
    PortfolioHoldings.any_instance.stubs(:provider_lots).returns({ @account.id => { symbol => provider_account.raw_holdings_payload["positions"].first["tax_lots"].map(&:with_indifferent_access) } })
  end

  def lot(date, qty, basis, value)
    { "original_purchase_date" => date, "quantity" => qty, "cost_basis" => basis, "current_value" => value, "position_type" => "LONG" }
  end

  test "lots that add up to the position are listed oldest first" do
    with_lots("PHBIG", units: 10, lots: [ lot("2025-06-01T04:00:00Z", "4", "500", "800"), lot("2025-01-01T05:00:00Z", "6", "500", "1200") ])

    big = PortfolioHoldings.new(user: @owner, account_id: @account.id).blocks.first.positions.find { |p| p.ticker == "PHBIG" }

    assert big.lots?
    assert_equal [ Date.new(2025, 1, 1), Date.new(2025, 6, 1) ], big.lots.map(&:acquired_on)
    assert_equal BigDecimal("300"), big.lots.last.gain
    assert_equal BigDecimal("125"), big.lots.first.unit_cost.nonzero? && big.lots.last.unit_cost
  end

  test "lots that do not add up to the position are dropped, not patched" do
    with_lots("PHBIG", units: 10, lots: [ lot("2025-01-01T05:00:00Z", "4", "500", "800"), lot("2025-06-01T04:00:00Z", "3", "300", "600") ])

    big = PortfolioHoldings.new(user: @owner, account_id: @account.id).blocks.first.positions.find { |p| p.ticker == "PHBIG" }

    assert_empty big.lots
    assert_not big.lots?
  end

  test "a lot with no date or basis keeps its missing values missing" do
    with_lots("PHBIG", units: 10, lots: [ lot(nil, "4", nil, "800"), lot("2025-06-01T04:00:00Z", "6", "500", nil) ])

    lots = PortfolioHoldings.new(user: @owner, account_id: @account.id).blocks.first.positions.find { |p| p.ticker == "PHBIG" }.lots
    undated = lots.find { |l| l.acquired_on.nil? }

    assert_nil undated.cost_basis
    assert_nil undated.gain
    assert_nil lots.find { |l| l.acquired_on }.market_value
  end

  # ---- page ----

  test "the page renders the account, a sortable header and the allocation chart" do
    sign_in @owner
    get portfolio_holdings_path(account: @account.id, sort: "gain", dir: "asc")

    assert_response :success
    assert_select "[data-testid=holdings-account]", count: 1
    assert_select "[data-testid=holdings-chart]"
    assert_select "th a[aria-sort=ascending]", text: /Gain/
    assert_select "[data-testid=holding-row]", count: 3
  end

  test "a position with lots gets a toggle and hidden lot rows" do
    with_lots("PHBIG", units: 10, lots: [ lot("2025-01-01T05:00:00Z", "6", "500", "1200"), lot("2025-06-01T04:00:00Z", "4", "500", "800") ])
    sign_in @owner
    get portfolio_holdings_path(account: @account.id)

    assert_response :success
    assert_select "button[data-holding-lots-target=toggle][aria-expanded=false]", count: 1
    assert_select "tr[hidden][data-testid=lot-row]", count: 2
  end

  test "a position with a single lot can still be opened to see its purchase date" do
    with_lots("PHBIG", units: 10, lots: [ lot("2025-03-03T05:00:00Z", "10", "1000", "2000") ])
    sign_in @owner
    get portfolio_holdings_path(account: @account.id)

    assert_response :success
    assert_select "button[data-holding-lots-target=toggle]", count: 1
    assert_select "tr[hidden][data-testid=lot-row]", text: /March 03, 2025|Mar(ch)? 3, 2025|2025/
  end

  test "every hidden lot row has a toggle that controls it" do
    with_lots("PHBIG", units: 10, lots: [ lot("2025-01-01T05:00:00Z", "6", "500", "1200"), lot("2025-06-01T04:00:00Z", "4", "500", "800") ])
    sign_in @owner
    get portfolio_holdings_path(account: @account.id)

    toggle_keys = css_select("button[data-holding-lots-target=toggle]").map { |b| b["data-lots-key"] }.uniq
    lot_keys = css_select("tr[data-testid=lot-row]").map { |r| r["data-lots-for"] }.uniq

    assert_equal toggle_keys.sort, lot_keys.sort, "a lot row with no toggle can never be opened"
  end

  test "price and avg cost columns hide when the table is narrow and show when it has room" do
    sign_in @owner
    get portfolio_holdings_path(account: @account.id)

    assert_select "th.hidden.\\@3xl\\:table-cell", count: 2
    assert_select "table.\\@3xl\\:min-w-\\[820px\\]"
  end

  test "a long fractional quantity is shown without a screenful of digits" do
    crypto = Security.create!(ticker: "PHFRC", exchange_mic: "XNAS")
    @account.holdings.create!(security: crypto, date: Date.current, qty: BigDecimal("0.446965250369237877"), price: 750, amount: 335.21, currency: "USD")
    sign_in @owner
    get portfolio_holdings_path(account: @account.id)

    assert_match(/0\.44696525(?!\d)/, response.body)
    assert_no_match(/0\.446965250369237877/, response.body)
  end

  test "missing figures render as an em dash, not zero" do
    sign_in @owner
    get portfolio_holdings_path(account: @account.id)

    assert_response :success
    assert_select "tr[data-testid=holding-row]", text: /PHNCB/ do |rows|
      assert_match(/—/, rows.first.text)
    end
    assert_select "p", text: /no known cost basis/i
  end

  test "an account the member cannot see is a 404" do
    sign_in @member
    get portfolio_holdings_path(account: @account.id)

    assert_response :not_found
  end

  test "a member with no investment accounts gets an empty state" do
    sign_in users(:empty)
    get portfolio_holdings_path

    assert_response :success
    assert_select "[data-testid=holdings-account]", count: 0
  end

  test "requires sign in" do
    get portfolio_holdings_path

    assert_redirected_to new_session_path
  end
end
