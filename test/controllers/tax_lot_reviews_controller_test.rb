require "test_helper"

class TaxLotReviewsControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    @owner = users(:family_admin)
    @account = @owner.family.accounts.create!(name: "Lot Page Brokerage", balance: 5000, cash_balance: 0, currency: "USD", owner: @owner,
                                              status: "active", accountable: Investment.new(subtype: "brokerage"))
    security = Security.create!(ticker: "LOTPG", exchange_mic: "XNAS", name: "Lot Page Co")
    @account.holdings.create!(security: security, date: Date.current, qty: 10, price: 150, amount: 1500, currency: "USD", cost_basis: 100, cost_basis_source: "provider")
    PortfolioHoldings.any_instance.stubs(:provider_lots).returns({
      @account.id => { "LOTPG" => [ { "quantity" => 10, "cost_basis" => 1000, "current_value" => 1500, "original_purchase_date" => (Date.current - 350.days).iso8601 }.with_indifferent_access ] }
    })
  end

  test "requires authentication" do
    get tax_lot_review_path
    assert_redirected_to new_session_path
  end

  test "shows lots by holding period with the days until long-term and no tax advice" do
    sign_in @owner
    get tax_lot_review_path

    assert_response :success
    assert_match "LOTPG", response.body
    assert_match "Short-term", response.body
    assert_match "$500.00", response.body
    assert_match "16 days", response.body
    assert_no_match(/you should|we recommend|estimated tax|tax due|sell now/i, response.body)
    assert_match "no tax owed, no advice", response.body
  end

  test "is one tax workspace with in-page lot and harvest tabs" do
    sign_in @owner

    get tax_lot_review_path
    assert_response :success
    assert_select "nav[aria-label='Tax workspace'] a[aria-current=page]", text: "Lots & holding period"
    assert_select "a[href=?]", tax_lot_review_path(tab: "harvest"), text: "Loss harvest review"
    assert_no_match(/Tax-Loss Harvest/, response.body)

    get tax_lot_review_path(tab: "harvest")
    assert_response :success
    assert_select "nav[aria-label='Tax workspace'] a[aria-current=page]", text: "Loss harvest review"
    assert_match "Harvest candidates", response.body
    assert_match "How to read this", response.body
  end

  test "ignores an unknown tax workspace tab" do
    sign_in @owner
    get tax_lot_review_path(tab: "not-real")

    assert_response :success
    assert_select "nav[aria-label='Tax workspace'] a[aria-current=page]", text: "Lots & holding period"
  end

  test "a member without access to the account sees none of its lots" do
    sign_in users(:empty)
    get tax_lot_review_path

    assert_response :success
    assert_no_match "LOTPG", response.body
  end

  test "names the positions without lot data and why, and never shows them to a member without access" do
    gap = Security.create!(ticker: "LOTGAP", exchange_mic: "XNAS", name: "No Lot Co")
    @account.holdings.create!(security: gap, date: Date.current, qty: 3, price: 10, amount: 30, currency: "USD", cost_basis: 8, cost_basis_source: "provider")

    sign_in @owner
    get tax_lot_review_path
    assert_select "details summary", text: /no broker lot data/
    assert_select "details", text: /Lot Page Brokerage/
    assert_select "details", text: /LOTGAP/
    assert_select "details", text: /does not send tax lots/

    sign_in users(:empty)
    get tax_lot_review_path
    assert_no_match "LOTGAP", response.body
  end

  def add_second_ticker(ticker:, account: @account, qty: 5, price: 20, basis: 30, bought: 500.days.ago.to_date)
    security = Security.create!(ticker: ticker, exchange_mic: "XNAS", name: "#{ticker} Co")
    account.holdings.create!(security: security, date: Date.current, qty: qty, price: price, amount: qty * price, currency: "USD", cost_basis: basis, cost_basis_source: "provider")
    existing = PortfolioHoldings.any_instance.stubs(:provider_lots)
    @lots_by_account ||= { @account.id => { "LOTPG" => [ { "quantity" => 10, "cost_basis" => 1000, "current_value" => 1500, "original_purchase_date" => (Date.current - 350.days).iso8601 }.with_indifferent_access ] } }
    @lots_by_account[account.id] ||= {}
    @lots_by_account[account.id][ticker] = [ { "quantity" => qty, "cost_basis" => qty * basis, "current_value" => qty * price, "original_purchase_date" => bought.iso8601 }.with_indifferent_access ]
    PortfolioHoldings.any_instance.stubs(:provider_lots).returns(@lots_by_account)
  end

  test "filters the lots table by ticker and by term without changing the page totals" do
    add_second_ticker(ticker: "LOTZZ")
    sign_in @owner

    get tax_lot_review_path(ticker: "lotzz")
    assert_response :success
    assert_select "table[data-testid=lots-table] tbody tr", count: 1
    assert_select "table[data-testid=lots-table] tbody", text: /LOTZZ/
    assert_select "table[data-testid=lots-table] tbody", text: /LOTPG/, count: 0
    assert_select "[data-testid=lots-filter-note]", text: /1 of 2/

    get tax_lot_review_path(term: "long")
    assert_select "table[data-testid=lots-table] tbody tr", count: 1
    assert_select "table[data-testid=lots-table] tbody", text: /Long-term/

    get tax_lot_review_path(term: "bogus")
    assert_response :success
    assert_select "table[data-testid=lots-table] tbody tr", count: 2

    get tax_lot_review_path(ticker: "<script>alert(1)</script>")
    assert_response :success
    assert_no_match(/<script>alert/, response.body)
    assert_select "table[data-testid=lots-table] tbody tr", count: 0
  end

  test "sorts lots by gain either way and ignores unknown sorts" do
    add_second_ticker(ticker: "LOTZZ")
    sign_in @owner

    get tax_lot_review_path(sort: "gain", dir: "desc")
    tickers = css_select("table[data-testid=lots-table] tbody tr td:first-child").map { |c| c.text.strip }
    assert_equal %w[LOTPG LOTZZ], tickers
    assert_select "th a[aria-sort=descending]"

    get tax_lot_review_path(sort: "gain", dir: "asc")
    tickers = css_select("table[data-testid=lots-table] tbody tr td:first-child").map { |c| c.text.strip }
    assert_equal %w[LOTZZ LOTPG], tickers

    get tax_lot_review_path(sort: "nope")
    assert_response :success
  end

  test "exports the measured lots as a CSV of the signed-in member's own accounts only" do
    sign_in @owner
    get tax_lot_review_path(format: :csv)

    assert_response :success
    assert_equal "text/csv", response.media_type
    assert_match(/attachment; filename="tax-lots-\d{4}-\d{2}-\d{2}\.csv"/, response.headers["Content-Disposition"])
    rows = CSV.parse(response.body, headers: true)
    assert_equal [ "Ticker", "Account", "Acquired", "Term", "Quantity", "Cost basis", "Market value", "Unrealized gain/loss", "Currency" ], rows.headers
    assert_equal 1, rows.size
    assert_equal "LOTPG", rows.first["Ticker"]
    assert_equal "short", rows.first["Term"]
    assert_equal "500.0", rows.first["Unrealized gain/loss"]

    sign_in users(:family_member)
    get tax_lot_review_path(format: :csv)
    assert_equal 0, CSV.parse(response.body, headers: true).size
  end

  test "the CSV follows the current filter and neutralises spreadsheet formulas" do
    @account.update!(name: "=HYPERLINK(\"http://evil.test\")")
    add_second_ticker(ticker: "LOTZZ")
    sign_in @owner

    get tax_lot_review_path(format: :csv, ticker: "LOTZZ")
    rows = CSV.parse(response.body, headers: true)
    assert_equal [ "LOTZZ" ], rows.map { |row| row["Ticker"] }
    assert rows.first["Account"].start_with?("'="), "formula-leading text must be escaped, got #{rows.first["Account"].inspect}"
  end

  test "the CSV needs sign in and offers a download link on the lots tab only" do
    get tax_lot_review_path(format: :csv)
    assert_redirected_to new_session_path

    sign_in @owner
    get tax_lot_review_path
    assert_select "a[href*='format=csv']", text: /Download CSV/
    get tax_lot_review_path(tab: "harvest")
    assert_select "a[href*='format=csv']", count: 0
  end

  test "harvest tab shows realized gains as unavailable when no sale could be measured" do
    unheld = Security.create!(ticker: "LOTUNK", exchange_mic: "XNAS", name: "Never Held Co")
    create_trade(unheld, account: @account, qty: -3, date: Date.current - 2, price: 20)
    sign_in @owner

    get tax_lot_review_path(tab: "harvest")

    assert_response :success
    assert_select "[data-testid=realized-ytd]", text: "—", count: 1
    assert_select "[data-testid=realized-ytd]", text: /\$/, count: 0
    assert_match I18n.t("tax_loss_harvests.show.summary.realized_hint", count: 1), response.body
  end
end
