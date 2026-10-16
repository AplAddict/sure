require "test_helper"

# Options section on the research ticker page (GET /research/:ticker). Same approved OptionsDesk
# read model, all accessible accounts, account-qualified rows, shown even for option-only tickers.
class TickerOptionsSectionTest < ActionDispatch::IntegrationTest
  NOW = Time.utc(2026, 10, 15, 15, 0)
  EXPIRATION = Date.new(2026, 11, 13)
  BANNED = /cash-secured|safe|best|opportunity|top ideas|sell|buy now|trade now|execute|place order/i

  setup do
    travel_to NOW
    ensure_tailwind_build
    @owner = users(:family_admin)
    @member = users(:family_member)
    @other_user = users(:empty)
    sign_in @owner
  end

  teardown { travel_back }

  def broker_account(owner: @owner, family: @owner.family, name: nil, freshness: Time.current, positions: [], raw_options_payload: positions, currency: "USD")
    suffix = SecureRandom.hex(4)
    account = family.accounts.create!(name: name || "Desk #{suffix}", balance: 1000, cash_balance: 0, currency: currency, owner: owner,
                                      status: "active", accountable: Investment.new(subtype: "brokerage"))
    item = SnaptradeItem.create!(family: family, name: "Desk item #{suffix}", client_id: "client-#{suffix}", consumer_key: "key-#{suffix}", status: "good")
    provider = SnaptradeAccount.create!(snaptrade_item: item, snaptrade_account_id: "desk-#{suffix}", name: account.name, currency: currency,
                                        current_balance: 1000, last_holdings_sync: freshness, raw_options_payload: raw_options_payload)
    AccountProvider.create!(account: account, provider: provider)
    [ account, provider ]
  end

  def position(symbol: "NVDA  261113P00215000", type: "PUT", strike: "215", qty: "1", price: "2", basis: "1", multiplier: "100", currency: "USD")
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

  def security(ticker)
    Security.find_or_create_by!(ticker: ticker) { |record| record.name = ticker }
  end

  def holding(account:, provider:, ticker:, qty:)
    Holding.create!(account: account, account_provider: provider.account_provider, security: security(ticker), date: NOW.to_date,
                    qty: qty, price: 1, amount: qty, currency: account.currency)
  end

  def open_ticker(ticker)
    get research_ticker_path(ticker)
    assert_response :success
  end

  def section_text
    css_select("[data-testid=ticker-options]").first.text.squish
  end

  test "an option-only ticker with no shares still shows its option rows, account-qualified" do
    account, = broker_account(name: "Options Only Brokerage", positions: [ position ])
    security("NVDA")
    open_ticker("NVDA")

    assert_select "[data-testid=ticker-options]", count: 1
    assert_select "[data-testid=ticker-options-row]", count: 1
    assert_select "[data-testid=ticker-options-row][data-account-id=?][data-contract=?]", account.id, "NVDA  261113P00215000"
    assert_includes section_text, "Options Only Brokerage"
    assert_select "[data-testid=ticker-options-subtotal]", count: 1
  end

  test "the old raw snapshot section is replaced by the new one" do
    account, provider = broker_account(positions: [ position ])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 10)
    open_ticker("NVDA")

    assert_select "h2", text: "Options positions", count: 0
    assert_no_match(/Read-only SnapTrade contract snapshot/, response.body)
    assert_select "[data-testid=ticker-options]", count: 1
    assert_select "[data-testid=ticker-options-ledger]", count: 1
  end

  test "the ledger is a labelled scrollable semantic table with an account column and no day P&L column" do
    broker_account(positions: [ position ])
    security("NVDA")
    open_ticker("NVDA")

    assert_select "div.overflow-x-auto[role=region][tabindex='0'][aria-label] table[data-testid=ticker-options-ledger]", count: 1
    assert_select "table[data-testid=ticker-options-ledger] caption", count: 1
    headers = css_select("table[data-testid=ticker-options-ledger] thead th[scope=col]").map { |th| th.text.squish }
    assert_equal 8, headers.size
    [ /Contract/, /Account/, /Expiry/, /Qty/, /Mark/, /Total P&L/, /delta/i, /Evidence/ ].each_with_index { |pattern, index| assert_match pattern, headers[index] }
    assert_includes section_text, "Day P&L unavailable - position change unknown"
  end

  test "rows from different accounts stay separate and the subtotal comes from the group" do
    first, = broker_account(name: "First Brokerage", positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215", qty: "1", price: "99", basis: "10") ])
    second, = broker_account(name: "Second Brokerage", positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215", qty: "2", price: "99", basis: "10") ])
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "12.40", ask: "12.60")
    security("AAPL")
    open_ticker("AAPL")

    assert_equal [ first.id, second.id ].sort, css_select("[data-testid=ticker-options-row]").map { |row| row["data-account-id"] }.sort
    assert_select "[data-testid=ticker-options-subtotal]", count: 1
    assert_match(/\$750\.00/, css_select("[data-testid=ticker-options-subtotal]").first.text)
    assert_no_match(/\$99\.00/, section_text)
  end

  test "matching is exact on the underlying, never by substring" do
    broker_account(positions: [ position, position(symbol: "NV    261113P00100000", strike: "100") ])
    security("NV")
    security("NVDA")
    open_ticker("NV")

    assert_select "[data-testid=ticker-options-row]", count: 1
    assert_select "[data-testid=ticker-options-row][data-contract=?]", "NV    261113P00100000"
    assert_no_match(/NVDA/, css_select("[data-testid=ticker-options-ledger]").first.text)
  end

  test "a ticker you do not hold and have no option rows for shows no options section at all" do
    broker_account(positions: [ position ])
    security("ZZNO")
    open_ticker("ZZNO")

    assert_select "[data-testid=ticker-options]", count: 0
    assert_select "[data-testid^=ticker-options]", count: 0
    assert_select "h2", text: "Options positions", count: 0
  end

  test "a ticker you do not hold stays quiet even when the broker data is stale" do
    broker_account(freshness: NOW - 40.hours, positions: [])
    security("ZZNO")
    open_ticker("ZZNO")

    assert_select "[data-testid^=ticker-options]", count: 0
  end

  test "a held ticker with no option rows says there are no open contracts for it" do
    account, provider = broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215") ])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 10)
    open_ticker("NVDA")

    assert_select "[data-testid=ticker-options-empty]", text: /No open option contracts for NVDA/
    assert_select "[data-testid=ticker-options-ledger]", count: 0
    assert_select "[data-testid=ticker-options-source-banner]", count: 0
  end

  test "an empty readable snapshot for a held ticker shows the empty banner and line" do
    account, provider = broker_account(positions: [])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 10)
    open_ticker("NVDA")

    assert_select "[data-testid=ticker-options-source-banner]", text: /No open option contracts/
    assert_select "[data-testid=ticker-options-empty]", text: /No open option contracts for NVDA/
  end

  test "stale and unavailable sources for a held ticker show the desk banner and never claim no open contracts" do
    { "stale" => [ NOW - 40.hours, [], /Broker snapshot is stale/ ],
      "unavailable" => [ NOW, "not-an-array", /Broker option data unavailable/ ] }.each do |label, (freshness, payload, banner)|
      account, provider = broker_account(freshness: freshness, raw_options_payload: payload)
      holding(account: account, provider: provider, ticker: "NVDA", qty: 10)
      open_ticker("NVDA")

      assert_select "[data-testid=ticker-options]", count: 1, message: label
      assert_select "[data-testid=ticker-options-source-banner]", text: banner, message: label
      assert_select "[data-testid=ticker-options-unavailable]", count: 1, message: label
      assert_select "[data-testid=ticker-options-empty]", count: 0, message: label
      assert_no_match(/No open option contracts/i, section_text, label)
      account.holdings.destroy_all
      account.update_columns(status: "disabled")
    end
  end

  test "rows with a stale snapshot show the banner next to the rows and say Stale" do
    broker_account(freshness: NOW - 40.hours, positions: [ position(price: "12.5") ])
    security("NVDA")
    open_ticker("NVDA")

    assert_select "[data-testid=ticker-options-source-banner]", text: /Broker snapshot is stale/
    text = css_select("[data-testid=ticker-options-row]").first.text.squish
    assert_not_includes text, "$12.50"
    assert_includes text, "Stale"
  end

  test "an unreadable source withholds the subtotal with the desk wording" do
    broker_account(positions: [ position ])
    broker_account(raw_options_payload: "not-an-array")
    security("NVDA")
    open_ticker("NVDA")

    subtotal = css_select("[data-testid=ticker-options-subtotal]").first.text.squish
    assert_match(/1 broker source\(s\) unreadable - totals withheld/, subtotal)
    assert_no_match(/\$\d/, subtotal)
  end

  test "a member sees only option rows from accounts shared with them" do
    broker_account(name: "Private Owner Account", positions: [ position ])
    shared, = broker_account(name: "Shared Desk Account", positions: [ position(qty: "3") ])
    broker_account(owner: @other_user, family: @other_user.family, name: "Stranger Account", positions: [ position ])
    AccountShare.create!(account: shared, user: @member, permission: "read_only")
    security("NVDA")

    sign_in @member
    open_ticker("NVDA")
    assert_select "[data-testid=ticker-options-row]", count: 1
    assert_select "[data-testid=ticker-options-row][data-account-id=?]", shared.id
    assert_no_match(/Private Owner Account|Stranger Account/, response.body)
  end

  test "covered-call and put sections are filtered to this ticker across accessible accounts" do
    account, provider = broker_account(positions: [])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    exclusion = Options::IdeaScanner::Exclusion.new(kind: :covered_call, account_id: account.id, account_name: account.name, underlying: "NVDA",
                                                    contract: "NVDA261113C00250000", option_type: "CALL", expiration: EXPIRATION, strike: BigDecimal("250"),
                                                    reasons: %i[insufficient_shares])
    other = exclusion.dup.tap { |copy| copy.underlying = "AAPL"; copy.contract = "AAPL261113C00250000" }
    put = Options::IdeaScanner::Exclusion.new(kind: :cash_needed_put, account_id: account.id, account_name: account.name, underlying: "NVDA",
                                              contract: "NVDA261113P00215000", option_type: "PUT", expiration: EXPIRATION, strike: BigDecimal("215"),
                                              reasons: %i[no_cash_data])
    other_put = put.dup.tap { |copy| copy.underlying = "AAPL"; copy.contract = "AAPL261113P00215000" }
    scan = ->(ideas, exclusions) { Options::IdeaScanner::Result.new(ideas: ideas, exclusions: exclusions, candidates_count: ideas.size, joint_exposure_note: Options::IdeaScanner::JOINT_EXPOSURE_NOTE) }
    base = OptionsDesk.new(user: @owner, now: NOW).result
    stubbed = base.with(ideas: OptionsDesk::Ideas.new(covered_calls: scan.call([], [ exclusion, other ]), puts: scan.call([], [ put, other_put ])))
    OptionsDesk.any_instance.stubs(:result).returns(stubbed)
    open_ticker("NVDA")

    assert_select "[data-testid=ticker-options-ideas]", count: 1
    assert_select "[data-testid=ticker-options-puts-unavailable]", text: /Put screening unavailable - collateral not verified/
    text = section_text
    assert_includes text, "Research only"
    assert_includes text, "NVDA261113C00250000"
    assert_includes text, "NVDA261113P00215000"
    assert_no_match(/AAPL/, text)
    assert_no_match BANNED, text
  end

  test "the section links to the full desk without a scope param and has no write or trade controls" do
    broker_account(positions: [ position ])
    security("NVDA")
    open_ticker("NVDA")

    assert_select "[data-testid=ticker-options] a[href=?]", options_review_path, text: "Open full Options Desk"
    assert_select "[data-testid=ticker-options] form, [data-testid=ticker-options] button, [data-testid=ticker-options] input, [data-testid=ticker-options] select, [data-testid=ticker-options] textarea", count: 0
    assert_no_match BANNED, section_text
  end

  test "account names are escaped" do
    broker_account(name: "<img src=x onerror=alert(1)>", positions: [ position ])
    security("NVDA")
    open_ticker("NVDA")

    assert_select "[data-testid=ticker-options] img", count: 0
  end

  test "the ticker page computes the options desk exactly once, across all accessible accounts" do
    broker_account(positions: [ position ])
    security("NVDA")
    real = OptionsDesk.new(user: @owner, now: NOW).result
    OptionsDesk.expects(:new).once.with(has_entries(account_id: nil)).returns(stub(result: real))

    open_ticker("NVDA")
    assert_select "[data-testid=ticker-options-row]", count: 1
  end
  test "a ticker held only in non-broker accounts shows no options section and no broker-outage notice" do
    account = @owner.family.accounts.create!(name: "Manual Only", balance: 1000, cash_balance: 0, currency: "USD", owner: @owner,
                                             status: "active", accountable: Investment.new(subtype: "brokerage"))
    security("NVDA")
    Holding.create!(account: account, security: security("NVDA"), date: NOW.to_date, qty: 10, price: 1, amount: 10, currency: "USD")
    open_ticker("NVDA")

    assert_select "[data-testid=ticker-options]", count: 0
    assert_no_match(/Broker option data|open contracts may be missing/i, response.body)
  end

  test "a user with no broker links at all never runs the options desk for a ticker page" do
    OptionsDesk.expects(:new).never
    open_ticker("AAPL")

    assert_select "[data-testid=ticker-options]", count: 0
  end

  test "an unreadable broker account still surfaces the unavailable notice for a ticker held in it" do
    account, provider = broker_account(raw_options_payload: "not-an-array")
    holding(account: account, provider: provider, ticker: "NVDA", qty: 10)
    open_ticker("NVDA")

    assert_select "[data-testid=ticker-options-source-banner]", count: 1
    assert_select "[data-testid=ticker-options-empty]", count: 0
  end

  test "a ticker held in a manual account and in an unreadable broker account keeps the broker notice" do
    manual = @owner.family.accounts.create!(name: "Manual Mixed", balance: 1000, cash_balance: 0, currency: "USD", owner: @owner,
                                            status: "active", accountable: Investment.new(subtype: "brokerage"))
    Holding.create!(account: manual, security: security("NVDA"), date: NOW.to_date, qty: 10, price: 1, amount: 10, currency: "USD")
    account, provider = broker_account(raw_options_payload: "not-an-array")
    holding(account: account, provider: provider, ticker: "NVDA", qty: 10)
    open_ticker("NVDA")

    assert_select "[data-testid=ticker-options-source-banner]", count: 1
  end

  test "covered-call contract counts are pluralised correctly" do
    account, provider = broker_account(positions: [])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 100)
    [ [ 235, "2.70", "2.90" ], [ 240, "1.80", "2.00" ] ].each { |strike, bid, ask| quote(type: "CALL", strike: strike, bid: bid, ask: ask, open_interest: 500) }
    open_ticker("NVDA")

    text = section_text
    assert_match(/up to 1 contract\b/, text)
    assert_no_match(/up to 1 contracts/, text)
  end
end
