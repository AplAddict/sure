require "test_helper"

# Adversarial suite for options on holding drawers (HoldingsController#show) and
# ticker pages (ResearchController#ticker). Written from the binding contracts
# alone (options-holdings-contract.md + options-desk-display-contract.md).
class OptionsUnderlyingAdversarialTest < ActionDispatch::IntegrationTest
  NOW = Time.utc(2026, 10, 15, 15, 0)
  EXPIRATION = Date.new(2026, 11, 13)
  NVDA_PUT = "NVDA  261113P00215000".freeze
  BANNED_COPY = [
    "cash-secured", "safe", "best", "opportunity", "top ideas", "sell",
    "buy now", "trade now", "execute", "place order"
  ].freeze
  PUT_HEADING = "Put screening unavailable - collateral not verified".freeze
  DAY_LINE = "Day P&L unavailable - position change unknown".freeze

  setup do
    ensure_tailwind_build
    travel_to NOW
    @owner = users(:family_admin)
    @member = users(:family_member)
    @other_user = users(:empty)
  end

  teardown { travel_back }

  # ---------------------------------------------------------------- (a) privacy

  test "ticker page: an unshared member never sees the owner's option rows, contract, account name or quantity" do
    account, = owner_book(name: "OwnerPrivateBrokerageZXQ", qty: "8881")
    sign_in @member

    get_ticker("NVDA")

    assert_no_leak(response.body, account: account, qty: "8881")
    assert_select "[data-testid=ticker-options-row]", count: 0
  end

  test "ticker page: a shared account becomes visible while an unshared sibling stays hidden" do
    hidden, = broker_account(name: "HiddenSiblingZXQ", positions: [ position(symbol: "NVDA  261113P00190000", strike: "190", qty: "7771") ])
    shared, = broker_account(name: "SharedVisibleAcct", positions: [ position(qty: "3") ])
    security("NVDA")
    AccountShare.create!(account: shared, user: @member, permission: "read_only")
    sign_in @member

    get_ticker("NVDA")

    rows = css_select("[data-testid=ticker-options-row]")
    assert_equal 1, rows.size
    assert_equal shared.id, rows.first["data-account-id"]
    assert_equal NVDA_PUT, rows.first["data-contract"]
    assert_includes section_text("ticker-options"), "SharedVisibleAcct"
    assert_no_leak(response.body, account: hidden, qty: "7771", contract: "NVDA  261113P00190000")
    assert_not_includes response.body, "NVDA  261113P00190000"
  end

  test "ticker page: a user in a different family sees nothing from the owner's book" do
    account, = owner_book(name: "OwnerPrivateBrokerageZXQ", qty: "8881")
    sign_in @other_user

    get_ticker("NVDA")

    assert_no_leak(response.body, account: account, qty: "8881")
    assert_select "[data-testid=ticker-options-row]", count: 0
  end

  test "drawer: account A's drawer never shows account B's contracts for the same ticker" do
    a, a_provider = broker_account(name: "AlphaDrawerAcct", positions: [ position(symbol: NVDA_PUT, qty: "3") ])
    b, b_provider = broker_account(name: "BetaDrawerAcct", positions: [ position(symbol: "NVDA  261113P00190000", strike: "190", qty: "7771") ])
    holding_a = holding(account: a, provider: a_provider, ticker: "NVDA", qty: 300)
    holding(account: b, provider: b_provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_drawer(holding_a)

    rows = css_select("[data-testid=holding-options-row]")
    assert_equal 1, rows.size
    assert_equal a.id, rows.first["data-account-id"]
    assert_equal NVDA_PUT, rows.first["data-contract"]
    section = section_html("holding-options")
    assert_not_includes section, "BetaDrawerAcct"
    assert_not_includes section, "NVDA  261113P00190000"
    assert_not_includes section, b.id
    assert_not_includes section_text("holding-options"), "7771"
  end

  test "drawer: a holding the user cannot access is not found and leaks nothing" do
    account, provider = broker_account(name: "OwnerPrivateBrokerageZXQ", positions: [ position(qty: "8881") ])
    private_holding = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)

    [ @member, @other_user ].each do |user|
      sign_in user
      get holding_path(private_holding)
      assert_response :not_found
      assert_no_leak(response.body, account: account, qty: "8881")
      get holding_path(private_holding), params: { account: account.id }, headers: { "Turbo-Frame" => "drawer" }
      assert_response :not_found
      assert_no_leak(response.body, account: account, qty: "8881")
    end
  end

  test "drawer: a member with a share sees the shared account's rows and never the unshared sibling's" do
    hidden, hidden_provider = broker_account(name: "HiddenSiblingZXQ", positions: [ position(symbol: "NVDA  261113P00190000", strike: "190", qty: "7771") ])
    holding(account: hidden, provider: hidden_provider, ticker: "NVDA", qty: 300)
    shared, shared_provider = broker_account(name: "SharedVisibleAcct", positions: [ position(qty: "3") ])
    shared_holding = holding(account: shared, provider: shared_provider, ticker: "NVDA", qty: 100)
    AccountShare.create!(account: shared, user: @member, permission: "read_only")
    sign_in @member

    get_drawer(shared_holding)

    rows = css_select("[data-testid=holding-options-row]")
    assert_equal [ shared.id ], rows.map { |row| row["data-account-id"] }
    assert_no_leak(response.body, account: hidden, qty: "7771", contract: "NVDA  261113P00190000")
    assert_not_includes response.body, "NVDA  261113P00190000"
  end

  test "drawer: a holding in a non-visible account never falls back to the user's other accounts" do
    visible, = broker_account(name: "VisibleSiblingAcct", positions: [ position(symbol: "NVDA  261113P00190000", strike: "190", qty: "7771") ])
    parked, parked_provider = broker_account(name: "ParkedDrawerAcct", positions: [ position(qty: "3") ])
    parked_holding = holding(account: parked, provider: parked_provider, ticker: "NVDA", qty: 300)
    parked.update_columns(status: "disabled")
    sign_in @owner

    get holding_path(parked_holding)

    assert_includes [ 200, 404 ], response.status
    next unless response.successful?

    assert_select "[data-testid=holding-options-row]", count: 0
    assert_not_includes response.body, "NVDA  261113P00190000"
    assert_not_includes section_html("holding-options"), visible.id
    assert_no_match(/No open option contracts/, section_text("holding-options"))
  end

  # ------------------------------------------------------ (b) underlying matching

  test "ticker page: NVD, NVDA2 and VDA never pull NVDA rows" do
    broker_account(positions: [ position(symbol: NVDA_PUT), position(symbol: "NVDAX 261113P00215000") ])
    %w[NVD NVDAX VDA].each { |ticker| security(ticker) }
    sign_in @owner

    %w[NVD VDA].each do |ticker|
      get_ticker(ticker)
      assert_select "[data-testid=ticker-options-row]", count: 0
      assert_not_includes response.body, NVDA_PUT, "#{ticker} page must not show NVDA contracts"
    end

    get_ticker("NVDAX")
    assert_not_includes response.body, NVDA_PUT
    css_select("[data-testid=ticker-options-row]").each do |row|
      assert_match(/\ANVDAX\s/, row["data-contract"], "NVDAX page showed #{row['data-contract']}")
    end
  end

  test "ticker page: NVDA never pulls NVDA2 or NVDAX rows" do
    broker_account(positions: [ position(symbol: NVDA_PUT), position(symbol: "NVDAX 261113P00215000"), position(symbol: "NVDAX 261113P00215000") ])
    security("NVDA")
    sign_in @owner

    get_ticker("NVDA")

    contracts = css_select("[data-testid=ticker-options-row]").map { |row| row["data-contract"] }
    assert_equal [ NVDA_PUT ], contracts
  end

  test "ticker page: a lower-case ticker param matches case-insensitively" do
    broker_account(positions: [ position ])
    security("NVDA")
    sign_in @owner

    get_ticker("nvda")

    assert_equal [ NVDA_PUT ], css_select("[data-testid=ticker-options-row]").map { |row| row["data-contract"] }
  end

  test "drawer: a holding named NVD never shows NVDA rows and NVDA never shows NVD or NVDA2 rows" do
    account, provider = broker_account(positions: [ position(symbol: NVDA_PUT), position(symbol: "NVD   261113P00100000", strike: "100"), position(symbol: "NVDAX 261113P00215000") ])
    short_holding = holding(account: account, provider: provider, ticker: "NVD", qty: 10)
    long_holding = holding(account: account, provider: provider, ticker: "NVDA", qty: 10)
    sign_in @owner

    get_drawer(short_holding)
    assert_not_includes section_html("holding-options"), NVDA_PUT
    css_select("[data-testid=holding-options-row]").each { |row| assert_match(/\ANVD\s/, row["data-contract"]) }

    get_drawer(long_holding)
    assert_equal [ NVDA_PUT ], css_select("[data-testid=holding-options-row]").map { |row| row["data-contract"] }
  end

  test "dotted and odd tickers do not crash either surface" do
    account, provider = broker_account(positions: [ position(symbol: "BRK.B 261113P00400000", strike: "400"), position(symbol: NVDA_PUT) ])
    brk = holding(account: account, provider: provider, ticker: "BRK.B", qty: 5)
    odd = holding(account: account, provider: provider, ticker: "ODD-1X", qty: 5)
    sign_in @owner

    [ brk, odd ].each do |record|
      get holding_path(record)
      assert_response :success
    end

    [ "BRK.B", "brk.b", "ODD-1X", "A%20B", "%27%3B--", "N" * 300 ].each do |ticker|
      get research_ticker_path(ticker)
      assert_operator response.status, :<, 500, "ticker #{ticker.inspect} raised"
    end
  end

  # ------------------------------------------------------- (c) option-only ticker

  test "ticker page: a put with no shares of the underlying still shows the options section and row" do
    account, = broker_account(name: "OptionsOnlyAcct", positions: [ position(qty: "2") ])
    security("NVDA")
    sign_in @owner

    get_ticker("NVDA")

    assert_select "[data-testid=ticker-options]", count: 1
    row = css_select("[data-testid=ticker-options-row]").first
    assert row, "option-only ticker must still list the contract"
    assert_equal account.id, row["data-account-id"]
    assert_equal NVDA_PUT, row["data-contract"]
    assert_includes row.text, "OptionsOnlyAcct"
  end

  test "ticker page: a ticker the user has nothing in shows no options section and does not 500" do
    broker_account(positions: [ position ])
    security("IBM")
    sign_in @owner

    get_ticker("IBM")

    assert_select "[data-testid=ticker-options]", count: 0
    assert_select "[data-testid=ticker-options-row]", count: 0
  end

  test "ticker page: an unheld ticker with an empty or unreadable source adds no options noise" do
    security("IBM")
    sign_in @owner

    broker_account(raw_options_payload: [])
    get_ticker("IBM")
    assert_select "[data-testid=ticker-options]", count: 0

    broker_account(raw_options_payload: "not-an-array")
    get_ticker("IBM")
    assert_select "[data-testid=ticker-options]", count: 0
  end

  test "ticker page: a user with no broker accounts at all gets no options section" do
    security("NVDA")
    sign_in @other_user

    get_ticker("NVDA")

    assert_select "[data-testid=ticker-options]", count: 0
  end

  # ------------------------------------------------------------ (d) source states

  test "an unreadable payload shows the unavailable wording and never 'No open option contracts' on both surfaces" do
    account, provider = broker_account(raw_options_payload: "not-an-array")
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    assert_select "[data-testid=ticker-options]", count: 1
    assert_select "[data-testid=ticker-options-source-banner]", text: /Broker option data unavailable/
    assert_select "[data-testid=ticker-options-unavailable]", count: 1
    assert_select "[data-testid=ticker-options-empty]", count: 0
    assert_select "[data-testid=ticker-options-row]", count: 0
    assert_no_match(/No open option contracts/, section_text("ticker-options"))

    get_drawer(held)
    assert_select "[data-testid=holding-options-source-banner]", text: /Broker option data unavailable/
    assert_select "[data-testid=holding-options-unavailable]", count: 1
    assert_select "[data-testid=holding-options-empty]", count: 0
    assert_no_match(/No open option contracts/, section_text("holding-options"))
  end

  test "a stale snapshot shows the stale banner, never the broker mark, and never the no-contracts line" do
    account, provider = broker_account(freshness: NOW - 40.hours, positions: [ position(price: "12.5", basis: "10") ])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    assert_select "[data-testid=ticker-options-source-banner]", text: /Broker snapshot is stale/
    assert_select "[data-testid=ticker-options-row]", count: 1
    assert_not_includes node_text("ticker-options-row"), "$12.50"
    assert_includes node_text("ticker-options-row"), "Stale"

    get_drawer(held)
    assert_select "[data-testid=holding-options-source-banner]", text: /Broker snapshot is stale/
    assert_not_includes node_text("holding-options-row"), "$12.50"
  end

  test "a stale snapshot with zero rows for the ticker shows stale wording, not 'No open option contracts for'" do
    account, provider = broker_account(freshness: NOW - 40.hours, positions: [])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    assert_select "[data-testid=ticker-options-source-banner]", text: /Broker snapshot is stale/
    assert_no_match(/No open option contracts for/, section_text("ticker-options"))
    assert_select "[data-testid=ticker-options-empty]", count: 0

    get_drawer(held)
    assert_select "[data-testid=holding-options-source-banner]", text: /Broker snapshot is stale/
    assert_no_match(/No open option contracts for/, section_text("holding-options"))
    assert_select "[data-testid=holding-options-empty]", count: 0
  end

  test "a readable empty source with held shares shows the empty line for the ticker" do
    account, provider = broker_account(raw_options_payload: [])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    assert_select "[data-testid=ticker-options-empty]", text: /No open option contracts for NVDA/
    assert_select "[data-testid=ticker-options-unavailable]", count: 0
    assert_select "[data-testid=ticker-options-row]", count: 0

    get_drawer(held)
    assert_select "[data-testid=holding-options-empty]", text: /No open option contracts for NVDA/
    assert_select "[data-testid=holding-options-unavailable]", count: 0
  end

  test "an available source with rows only for other underlyings still gets the per-ticker empty line" do
    account, provider = broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215") ])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    assert_select "[data-testid=ticker-options-empty]", text: /No open option contracts for NVDA/
    assert_select "[data-testid=ticker-options-row]", count: 0
    assert_not_includes section_html("ticker-options"), "AAPL"

    get_drawer(held)
    assert_select "[data-testid=holding-options-empty]", text: /No open option contracts for NVDA/
    assert_not_includes section_html("holding-options"), "AAPL"
  end

  test "an unreadable account does not let the drawer or ticker page total a readable sibling" do
    account, provider = broker_account(positions: [ position(price: "3", basis: "1") ])
    broker_account(raw_options_payload: "not-an-array")
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    quote(type: "PUT", strike: 215)
    sign_in @owner

    get_ticker("NVDA")
    subtotal = css_select("[data-testid=ticker-options-subtotal]").first
    assert subtotal, "missing ticker-options-subtotal"
    assert_no_match(/\$\d/, subtotal.text)
    assert_match(/—/, subtotal.text)
    assert_match(/unreadable/i, subtotal.text)
    assert_select "[data-testid=ticker-options-source-banner]", text: /Broker option data unavailable/

    get_drawer(held)
    drawer_subtotal = css_select("[data-testid=holding-options-subtotal]").first
    assert drawer_subtotal, "missing holding-options-subtotal"
    assert_match(/\$\d/, drawer_subtotal.text, "the drawer is scoped to its own readable account")
    assert_select "[data-testid=holding-options-source-banner]", count: 0
  end

  # ---------------------------------------------------------------- (e) numbers

  test "a nil cost basis shows an em dash with its cause, never $0.00, on both surfaces" do
    account, provider = broker_account(positions: [ position(price: "10", basis: nil) ])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    text = node_text("ticker-options-row")
    assert_match(/—/, text)
    assert_match(/cost basis/i, text)
    assert_no_match(/\$0\.00/, text)

    get_drawer(held)
    text = node_text("holding-options-row")
    assert_match(/—/, text)
    assert_match(/cost basis/i, text)
    assert_no_match(/\$0\.00/, text)
  end

  test "a true zero P&L renders $0.00" do
    account, provider = broker_account(positions: [ position(price: "10", basis: "10") ])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    assert_includes node_text("ticker-options-row"), "$0.00"
    get_drawer(held)
    assert_includes node_text("holding-options-row"), "$0.00"
  end

  test "an unknown currency code never raises and renders unavailable instead of a number" do
    account, provider = broker_account(positions: [ position(currency: "ZZZ") ])
    quote(currency: "ZZZ")
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    assert_select "[data-testid=ticker-options-row]", count: 1
    assert_match(/—/, node_text("ticker-options-subtotal"))
    assert_no_match(/\$|ZZZ\s*\d/, node_text("ticker-options-subtotal"))
    assert_no_match(/ZZZ\s*\d/, node_text("ticker-options-row"))

    get_drawer(held)
    assert_select "[data-testid=holding-options-row]", count: 1
    assert_no_match(/\$|ZZZ\s*\d/, node_text("holding-options-subtotal"))
  end

  test "mixed-currency accounts never pool a ticker subtotal" do
    broker_account(positions: [ position(price: "2", basis: "1") ])
    broker_account(currency: "CAD", positions: [ position(currency: "CAD", price: "2", basis: "1") ])
    security("NVDA")
    sign_in @owner

    get_ticker("NVDA")

    assert_select "[data-testid=ticker-options-row]", count: 2
    subtotal = css_select("[data-testid=ticker-options-subtotal]").first
    assert subtotal, "missing ticker-options-subtotal"
    assert_no_match(/\$\d|CA\$\d/, subtotal.text)
    assert_match(/—/, subtotal.text)
  end

  test "a blank currency group withholds its subtotal" do
    _account, provider = broker_account(positions: [ position(currency: "") ])
    provider.update_columns(currency: nil)
    security("NVDA")
    sign_in @owner

    get_ticker("NVDA")

    subtotal = css_select("[data-testid=ticker-options-subtotal]").first
    assert subtotal, "missing ticker-options-subtotal"
    assert_no_match(/\$\d/, subtotal.text)
    assert_match(/—/, subtotal.text)
  end

  test "a negative broker mark is unavailable, never $0.00 or a negative price" do
    account, provider = broker_account(positions: [ position(price: "-1", basis: "1") ])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    text = node_text("ticker-options-row")
    assert_match(/—/, text)
    assert_no_match(/\$0\.00|-\$1\.00|\$-1/, text)

    get_drawer(held)
    text = node_text("holding-options-row")
    assert_no_match(/\$0\.00|-\$1\.00|\$-1/, text)
  end

  test "day P&L is never a number: no column, and the position-change-unknown line is present" do
    account, provider = broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215", price: "12.5", basis: "10"), position ])
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "12.40", ask: "12.60")
    held = holding(account: account, provider: provider, ticker: "AAPL", qty: 300)
    security("NVDA")
    sign_in @owner

    get_ticker("AAPL")
    assert_includes section_text("ticker-options"), DAY_LINE
    assert_empty ledger_headers("ticker-options-ledger").grep(/Day P&L/i)
    assert_no_match(/Day P&L[^U]*[$+\-]?\d/, section_text("ticker-options").sub(DAY_LINE, ""))

    get_drawer(held)
    assert_includes section_text("holding-options"), DAY_LINE
    assert_empty ledger_headers("holding-options-ledger").grep(/Day P&L/i)
  end

  test "the mark is the direct quote when one is current and the broker mark otherwise" do
    account, provider = broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215", price: "99", basis: "10"),
                                                    position(symbol: "NVDA  261113P00215000", price: "7.25", basis: "5") ])
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "12.40", ask: "12.60")
    aapl = holding(account: account, provider: provider, ticker: "AAPL", qty: 10)
    nvda = holding(account: account, provider: provider, ticker: "NVDA", qty: 10)
    sign_in @owner

    get_drawer(aapl)
    row = node_text("holding-options-row")
    assert_includes row, "$12.50"
    assert_not_includes row, "$99.00", "the broker mark must not be shown when a direct quote is current"
    assert_includes row, "+$250.00"

    get_drawer(nvda)
    row = node_text("holding-options-row")
    assert_includes row, "$7.25"
  end

  test "an indicative wide quote is never totalled" do
    account, provider = broker_account(positions: [ position(price: "12.5", basis: "10") ])
    quote(bid: "1.00", ask: "3.00")
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    assert_includes node_text("ticker-options-row"), "Indicative"
    assert_no_match(/\$\d/, node_text("ticker-options-subtotal"))

    get_drawer(held)
    assert_no_match(/\$\d/, node_text("holding-options-subtotal"))
  end

  test "the subtotal is the desk group total, rendered once per ticker, never recomputed from rows" do
    a, a_provider = broker_account(positions: [ position(price: "3", basis: "1") ])
    b, = broker_account(positions: [ position(symbol: "NVDA  261113P00190000", strike: "190", price: "4", basis: "1") ])
    quote(type: "PUT", strike: 215, bid: "2.90", ask: "3.10")
    quote(type: "PUT", strike: 190, bid: "3.90", ask: "4.10")
    held = holding(account: a, provider: a_provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    assert_equal [ a.id, b.id ].sort, css_select("[data-testid=ticker-options-row]").map { |row| row["data-account-id"] }.sort
    assert_equal 1, css_select("[data-testid=ticker-options-subtotal]").size
    assert_includes node_text("ticker-options-subtotal"), "$500.00"

    get_drawer(held)
    assert_equal 1, css_select("[data-testid=holding-options-subtotal]").size
    assert_includes node_text("holding-options-subtotal"), "$200.00"
    assert_not_includes node_text("holding-options-subtotal"), "$500.00"
  end

  test "position-size delta figures stay privacy-masked" do
    account, provider = broker_account(positions: [ position(qty: "2") ])
    quote(type: "PUT", strike: 215)
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    assert css_select("[data-testid=ticker-options-row] .privacy-sensitive").any?, "delta/position figures must carry privacy-sensitive"

    get_drawer(held)
    assert css_select("[data-testid=holding-options-row] .privacy-sensitive").any?, "delta/position figures must carry privacy-sensitive"
  end

  # --------------------------------------------------------------------- (f) ideas

  test "put screening keeps its exact heading and never presents a put candidate" do
    shares, shares_provider = broker_account(name: "SharesDesk", positions: [])
    held = holding(account: shares, provider: shares_provider, ticker: "NVDA", qty: 300)
    quote(type: "PUT", strike: 215, bid: "4.00", ask: "4.20", open_interest: 500)
    sign_in @owner

    get_ticker("NVDA")
    puts_root = css_select("[data-testid=ticker-options-puts-unavailable]").first
    assert puts_root, "missing ticker-options-puts-unavailable"
    assert_includes puts_root.text.squish, PUT_HEADING
    assert_no_match(/candidate/i, puts_root.text)
    assert_no_match(/cash-secured/i, puts_root.text)

    get_drawer(held)
    puts_root = css_select("[data-testid=holding-options-puts-unavailable]").first
    assert puts_root, "missing holding-options-puts-unavailable"
    assert_includes puts_root.text.squish, PUT_HEADING
    assert_no_match(/candidate/i, puts_root.text)
  end

  test "covered-call candidates appear only under the account holding the shares" do
    shares, shares_provider = broker_account(name: "SharesAlphaAcct", positions: [])
    optionless, = broker_account(name: "NoSharesBetaAcct", positions: [ position(symbol: "NVDA  261113P00190000", strike: "190", qty: "1") ])
    held = holding(account: shares, provider: shares_provider, ticker: "NVDA", qty: 300)
    covered_call_quotes
    sign_in @owner

    get_ticker("NVDA")
    ideas = css_select("[data-testid=ticker-options-ideas]").first
    assert ideas, "missing ticker-options-ideas"
    assert_includes ideas.text, "SharesAlphaAcct"
    assert_includes ideas.text, "Research only"
    ideas.css("[data-testid=ticker-options-covered-call-idea]").each { |node| assert_equal shares.id, node["data-account-id"] }
    ideas.css("[data-testid=ticker-options-covered-call-exclusion]").each do |node|
      next unless node["data-account-id"] == optionless.id

      assert_includes node.text, "Shares not verified"
    end

    get_drawer(held)
    ideas = css_select("[data-testid=holding-options-ideas]").first
    assert ideas, "missing holding-options-ideas"
    assert_includes ideas.text, "Research only"
    assert_not_includes ideas.text, "NoSharesBetaAcct"
    ideas.css("[data-account-id]").each { |node| assert_equal shares.id, node["data-account-id"] }
  end

  test "the drawer's ideas and put exclusions come only from its own account when two accounts hold the ticker" do
    a, a_provider = broker_account(name: "AlphaIdeasAcct", positions: [])
    b, b_provider = broker_account(name: "BetaIdeasAcct", positions: [])
    holding_a = holding(account: a, provider: a_provider, ticker: "NVDA", qty: 300)
    holding_b = holding(account: b, provider: b_provider, ticker: "NVDA", qty: 100)
    covered_call_quotes
    quote(type: "PUT", strike: 215, bid: "4.00", ask: "4.20", open_interest: 500)
    sign_in @owner

    { holding_a => [ a, b ], holding_b => [ b, a ] }.each do |record, (own, other)|
      get_drawer(record)
      %w[holding-options-ideas holding-options-puts-unavailable].each do |hook|
        root = css_select("[data-testid=#{hook}]").first
        next unless root

        assert_not_includes root.text, other.name
        assert_not_includes root.to_s, other.id
        root.css("[data-account-id]").each { |node| assert_equal own.id, node["data-account-id"] }
      end
    end

    get_ticker("NVDA")
    ideas_text = section_text("ticker-options")
    assert_includes ideas_text, "AlphaIdeasAcct"
    assert_includes ideas_text, "BetaIdeasAcct"
  end

  test "a MINI-deliverable quote is never shown on either surface" do
    account, provider = broker_account(name: "SharesDesk", positions: [])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    covered_call_quotes
    mini = quote(type: "CALL", strike: 260, contract_size: "MINI", bid: "1.80", ask: "2.00", open_interest: 500)
    quote(type: "PUT", strike: 215, contract_size: "MINI", bid: "4.00", ask: "4.20", open_interest: 500)
    sign_in @owner

    get_ticker("NVDA")
    assert_includes response.body, "ticker-options"
    assert_not_includes section_html("ticker-options"), mini.contract_symbol
    assert_not_includes section_html("ticker-options"), "260"

    get_drawer(held)
    assert_includes response.body, "holding-options"
    assert_not_includes section_html("holding-options"), mini.contract_symbol
    assert_not_includes section_html("holding-options"), "260"
  end

  test "banned recommendation vocabulary is absent from both options sections with rows, ideas and exclusions on screen" do
    account, provider = broker_account(name: "Plain Brokerage", positions: [ position(symbol: "NVDA  261113C00230000", type: "CALL", strike: "230", qty: "-1") ])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    covered_call_quotes
    quote(type: "PUT", strike: 215)
    sign_in @owner

    get_ticker("NVDA")
    assert_select "[data-testid=ticker-options-row]", minimum: 1
    assert_clean_copy("ticker-options")

    get_drawer(held)
    assert_select "[data-testid=holding-options-row]", minimum: 1
    assert_clean_copy("holding-options")

    # also in the stale / unavailable / empty states
    each_source_state(provider: provider) do
      get_ticker("NVDA")
      assert_clean_copy("ticker-options")
      get_drawer(held)
      assert_clean_copy("holding-options")
    end
  end

  # ------------------------------------------------------------------- (g) XSS

  test "account names and contract strings are escaped inside both sections" do
    script = "<script>alert(1)</script>"
    breakout = '"><img src=x onerror=alert(1)>'
    script_account, script_provider = broker_account(name: script, positions: [ position, position(symbol: "NVDA  261113P00215000#{script}", strike: "216") ])
    broker_account(name: breakout, positions: [ position(symbol: "NVDA  261113P00190000", strike: "190") ])
    held = holding(account: script_account, provider: script_provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    assert_select "[data-testid=ticker-options-row]", minimum: 2
    assert_not_includes response.body, "<script>alert(1)</script>"
    assert_not_includes response.body, "<img src=x onerror"
    assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert_not_includes response.body, "<img src=x onerror"

    get_drawer(held)
    assert_not_includes response.body, "<script>alert(1)</script>"
  end

  # ------------------------------------------------------------- (h) structure

  test "ticker page: the ledger is a captioned, scrollable, semantic table with per-row hooks" do
    account, = broker_account(positions: [ position ])
    security("NVDA")
    sign_in @owner

    get_ticker("NVDA")

    assert_select "div[role=region][tabindex='0'][aria-label] table[data-testid=ticker-options-ledger]", count: 1
    assert_select "table[data-testid=ticker-options-ledger] caption", count: 1
    headers = ledger_headers("ticker-options-ledger")
    assert_equal 8, headers.size, headers.inspect
    [ /Contract/, /Account/, /Expiry/, /Qty/, /Mark/, /Total P&L/, /delta/i, /Evidence/ ].each_with_index { |pattern, index| assert_match pattern, headers[index] }
    assert_select "table[data-testid=ticker-options-ledger] tr[data-testid=ticker-options-row]", count: 1
    row = css_select("[data-testid=ticker-options-row]").first
    assert_equal account.id, row["data-account-id"]
    assert_equal NVDA_PUT, row["data-contract"]
    assert_select "[data-testid=ticker-options-ledger] article", count: 0
  end

  test "drawer: the ledger is a captioned, scrollable, semantic table without an account column" do
    account, provider = broker_account(positions: [ position ])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_drawer(held)

    assert_select "div[role=region][tabindex='0'][aria-label] table[data-testid=holding-options-ledger]", count: 1
    assert_select "table[data-testid=holding-options-ledger] caption", count: 1
    headers = ledger_headers("holding-options-ledger")
    assert_equal 7, headers.size, headers.inspect
    assert_empty headers.grep(/\AAccount/)
    [ /Contract/, /Expiry/, /Qty/, /Mark/, /Total P&L/, /delta/i, /Evidence/ ].each_with_index { |pattern, index| assert_match pattern, headers[index] }
    row = css_select("[data-testid=holding-options-row]").first
    assert_equal account.id, row["data-account-id"]
    assert_equal NVDA_PUT, row["data-contract"]
  end

  test "the full-desk links point at the options desk, with the account param only on the drawer" do
    account, provider = broker_account(positions: [ position ])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    links = css_select("[data-testid=ticker-options] a").select { |link| link.text.squish == "Open full Options Desk" }
    assert_equal 1, links.size
    assert_equal options_review_path, links.first["href"]

    get_drawer(held)
    links = css_select("[data-testid=holding-options] a").select { |link| link.text.squish == "Open full Options Desk" }
    assert_equal 1, links.size
    assert_equal options_review_path(account: account.id), links.first["href"]
  end

  test "the link is present in the unavailable and empty states too" do
    account, provider = broker_account(raw_options_payload: "not-an-array")
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_ticker("NVDA")
    assert_select "[data-testid=ticker-options] a[href=?]", options_review_path, text: "Open full Options Desk"
    get_drawer(held)
    assert_select "[data-testid=holding-options] a[href=?]", options_review_path(account: account.id), text: "Open full Options Desk"
  end

  test "neither section contains forms, inputs, submit buttons or write links" do
    account, provider = broker_account(positions: [ position ])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    covered_call_quotes
    sign_in @owner

    get_ticker("NVDA")
    assert_write_free("ticker-options")
    get_drawer(held)
    assert_write_free("holding-options")
  end

  test "the drawer section is a single root placed before the stock data section" do
    account, provider = broker_account(positions: [ position ])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    get_drawer(held)

    assert_select "[data-testid=holding-options]", count: 1
    body = response.body
    options_at = body.index('data-testid="holding-options"')
    stock_at = body.index(I18n.t("holdings.show.stock_data").gsub("&", "&amp;"))
    assert options_at
    assert stock_at, "stock data section missing"
    assert_operator options_at, :<, stock_at
  end

  test "the old raw snapshot 'Options positions' section is replaced, not duplicated" do
    broker_account(positions: [ position ])
    security("NVDA")
    sign_in @owner

    get_ticker("NVDA")

    assert_select "h2", text: "Options positions", count: 0
    assert_equal 1, css_select("[data-testid=ticker-options]").size
    assert_equal 1, css_select("[data-contract='#{NVDA_PUT}']").size
  end

  test "each request renders at most one OptionsDesk computation" do
    account, provider = broker_account(positions: [ position ])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    ticker_desk = OptionsDesk.new(user: @owner, now: NOW)
    OptionsDesk.expects(:new).at_most_once.returns(ticker_desk)
    get_ticker("NVDA")
    assert_select "[data-testid=ticker-options-row]", count: 1
    OptionsDesk.unstub(:new)

    drawer_desk = OptionsDesk.new(user: @owner, account_id: account.id, now: NOW)
    OptionsDesk.expects(:new).at_most_once.returns(drawer_desk)
    get_drawer(held)
    assert_select "[data-testid=holding-options-row]", count: 1
  end

  # --------------------------------------------------------- (i) unauthenticated

  test "anonymous visitors are redirected from the ticker page and the holding drawer" do
    account, provider = broker_account(positions: [ position ])
    held = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    security("NVDA")

    get research_ticker_path("NVDA")
    assert_redirected_to new_session_path
    get holding_path(held)
    assert_redirected_to new_session_path
    get holding_path(held), params: { account: account.id }
    assert_redirected_to new_session_path
  end

  # ---------------------------------------------------------- (j) hostile params

  test "hostile params cannot widen the ticker page scope for an unshared member" do
    account, = owner_book(name: "OwnerPrivateBrokerageZXQ", qty: "8881")
    sign_in @member

    [
      { account: account.id }, { account_id: account.id }, { user_id: @owner.id }, { family_id: @owner.family_id },
      { account: "garbage" }, { account: [ "x" ] }, { account: { id: account.id } }, { account: "1; DROP TABLE accounts;--" }
    ].each do |params|
      get research_ticker_path("NVDA"), params: params
      assert_response :success
      assert_no_leak(response.body, account: account, qty: "8881")
    end
  end

  test "hostile params cannot widen the ticker page for the owner into other scopes either" do
    broker_account(name: "OwnerOwn", positions: [ position ])
    stranger, = broker_account(owner: @other_user, family: @other_user.family, name: "StrangerAcctZXQ", positions: [ position(symbol: "NVDA  261113P00190000", strike: "190", qty: "7771") ])
    security("NVDA")
    sign_in @owner

    [ { account: stranger.id }, { account_id: stranger.id }, { account: "garbage" }, { account: [ "x" ] } ].each do |params|
      get research_ticker_path("NVDA"), params: params
      assert_response :success
      assert_equal [ NVDA_PUT ], css_select("[data-testid=ticker-options-row]").map { |row| row["data-contract"] }
      assert_no_leak(response.body, account: stranger, qty: "7771", contract: "NVDA  261113P00190000")
    end
  end

  test "hostile params cannot widen the holding drawer beyond its own account" do
    a, a_provider = broker_account(name: "AlphaDrawerAcct", positions: [ position ])
    b, b_provider = broker_account(name: "BetaDrawerAcct", positions: [ position(symbol: "NVDA  261113P00190000", strike: "190", qty: "7771") ])
    stranger, = broker_account(owner: @other_user, family: @other_user.family, name: "StrangerAcctZXQ", positions: [ position(symbol: "NVDA  261113P00180000", strike: "180", qty: "6661") ])
    holding_a = holding(account: a, provider: a_provider, ticker: "NVDA", qty: 300)
    holding(account: b, provider: b_provider, ticker: "NVDA", qty: 300)
    sign_in @owner

    [ { account: b.id }, { account_id: b.id }, { account: stranger.id }, { account: "garbage" }, { account: [ "x" ] }, { account: { id: b.id } }, { ticker: "AAPL" } ].each do |params|
      get holding_path(holding_a), params: params, headers: { "Turbo-Frame" => "drawer" }
      assert_response :success
      assert_equal [ a.id ], css_select("[data-testid=holding-options-row]").map { |row| row["data-account-id"] }.uniq, "params #{params.inspect} widened the drawer"
      assert_not_includes section_html("holding-options"), "BetaDrawerAcct"
      assert_not_includes response.body, "NVDA  261113P00180000"
    end
  end

  private
    def broker_account(owner: @owner, family: owner.family, currency: "USD", freshness: NOW, positions: [], raw_options_payload: positions, name: nil)
      suffix = SecureRandom.hex(4)
      account = family.accounts.create!(name: name || "Desk #{suffix}", balance: 1000, cash_balance: 0, currency: currency, owner: owner,
                                        status: "active", accountable: Investment.new(subtype: "brokerage"))
      item = SnaptradeItem.create!(family: family, name: "Desk item #{suffix}", client_id: "client-#{suffix}", consumer_key: "key-#{suffix}", status: "good")
      provider = SnaptradeAccount.create!(snaptrade_item: item, snaptrade_account_id: "desk-#{suffix}", name: account.name, currency: currency,
                                          current_balance: 1000, last_holdings_sync: freshness, raw_options_payload: raw_options_payload)
      AccountProvider.create!(account: account, provider: provider)
      [ account, provider ]
    end

    def position(symbol: NVDA_PUT, type: "PUT", strike: "215", qty: "1", price: "2", basis: "1", multiplier: "100", currency: "USD")
      { "instrument" => { "symbol" => symbol, "option_type" => type, "expiration_date" => EXPIRATION.to_s, "strike_price" => strike, "multiplier" => multiplier },
        "units" => qty, "price" => price, "cost_basis" => basis, "currency" => { "code" => currency } }
    end

    def quote(underlying: "NVDA", type: "PUT", strike: 215, expiration: EXPIRATION, bid: "2", ask: "2.20", **overrides)
      symbol = "#{underlying}#{expiration.strftime('%y%m%d')}#{type[0]}#{format('%08d', (BigDecimal(strike.to_s) * 1000).to_i)}"
      OptionQuote.create!({ contract_symbol: symbol, underlying: underlying, option_type: type, strike: strike, expiration: expiration,
                            bid: bid, ask: ask, last_price: "2.1", last_trade_at: NOW - 5.minutes, quote_time: NOW - 5.minutes,
                            session_date: Date.new(2026, 10, 15), underlying_price: "217.23", underlying_prev_close: "216",
                            open_interest: 100, contract_size: "REGULAR", fetched_at: NOW - 1.minute, source: "test", currency: "USD" }.merge(overrides))
    end

    def covered_call_quotes
      [ [ 235, "2.70", "2.90" ], [ 240, "1.80", "2.00" ] ].each do |strike, bid, ask|
        quote(type: "CALL", strike: strike, bid: bid, ask: ask, open_interest: 500)
      end
    end

    def security(ticker)
      Security.find_or_create_by!(ticker: ticker) { |record| record.name = ticker }
    end

    def holding(account:, provider:, ticker:, qty:)
      Holding.create!(account: account, account_provider: provider.account_provider, security: security(ticker), date: NOW.to_date,
                      qty: qty, price: 1, amount: qty, currency: account.currency)
    end

    # The owner's private NVDA book: one put, one holding of shares, a distinctive account name and quantity.
    def owner_book(name:, qty:)
      account, provider = broker_account(name: name, positions: [ position(qty: qty, price: "5", basis: "1") ])
      holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
      [ account, provider ]
    end

    def get_ticker(ticker)
      get research_ticker_path(ticker)
      assert_response :success
    end

    def get_drawer(record)
      get holding_path(record), params: { account: record.account_id }, headers: { "Turbo-Frame" => "drawer" }
      assert_response :success
    end

    def section_node(testid)
      css_select("[data-testid=#{testid}]").first
    end

    def section_text(testid)
      node = section_node(testid)
      assert node, "missing [data-testid=#{testid}]"
      node.text.squish
    end

    def node_text(testid)
      node = section_node(testid)
      assert node, "missing [data-testid=#{testid}]"
      node.text.squish
    end

    def section_html(testid)
      node = section_node(testid)
      assert node, "missing [data-testid=#{testid}]"
      node.to_s
    end

    def ledger_headers(testid)
      css_select("table[data-testid=#{testid}] thead th[scope=col]").map { |th| th.text.squish }
    end

    def assert_clean_copy(testid)
      node = section_node(testid)
      assert node, "missing [data-testid=#{testid}]"
      copy = ([ node.text ] + node.css("[aria-label], [title]").flat_map { |n| [ n["aria-label"], n["title"] ] }).compact.join(" ")
      BANNED_COPY.each do |word|
        assert_no_match(/#{Regexp.escape(word)}/i, copy, "#{testid} contains banned vocabulary #{word.inspect}")
      end
    end

    def assert_write_free(testid)
      root = section_node(testid)
      assert root, "missing [data-testid=#{testid}]"
      assert_empty root.css("form, input, select, textarea, button[type=submit], button:not([type]), input[type=submit]")
      assert_empty root.css("a[data-turbo-method], a[data-method], [formaction]")
      assert_empty root.css("a").select { |link| link["href"].to_s.match?(%r{/(trades|orders|transactions)/new|/orders}) }
    end

    def assert_no_leak(body, account:, qty:, contract: NVDA_PUT)
      assert_not_includes body, contract
      assert_not_includes body, account.name
      assert_no_match(/data-account-id=["']#{account.id}["']/, body)
      assert_no_match(/data-contract=["']#{Regexp.escape(contract)}["']/, body)
      assert_no_match(/\b#{Regexp.escape(qty)}\b/, css_select("[data-testid=ticker-options], [data-testid=holding-options]").map(&:to_s).join)
    end

    # Cycles an account's source through stale / unreadable / empty so copy scans cover every state.
    def each_source_state(provider:)
      [ { last_holdings_sync: NOW - 40.hours },
        { last_holdings_sync: NOW, raw_options_payload: "not-an-array" },
        { last_holdings_sync: NOW, raw_options_payload: [] } ].each do |attrs|
        provider.update!(attrs)
        yield
      end
    end
end
