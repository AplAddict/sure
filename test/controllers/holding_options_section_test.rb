require "test_helper"

# Options section inside the holding drawer (GET /holdings/:id). Data comes only from the
# approved OptionsDesk read model, scoped to the holding's own account. Fail closed.
class HoldingOptionsSectionTest < ActionDispatch::IntegrationTest
  NOW = Time.utc(2026, 10, 15, 15, 0)
  EXPIRATION = Date.new(2026, 11, 13)
  BANNED = /cash-secured|safe|best|opportunity|top ideas|sell|buy now|trade now|execute|place order/i

  setup do
    travel_to NOW
    @owner = users(:family_admin)
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

  def holding(account:, provider:, ticker:, qty:)
    security = Security.find_or_create_by!(ticker: ticker) { |record| record.name = ticker }
    Holding.create!(account: account, account_provider: provider.account_provider, security: security, date: NOW.to_date,
                    qty: qty, price: 1, amount: qty, currency: account.currency)
  end

  def open_drawer(holding)
    get holding_path(holding)
    assert_response :success
  end

  def section_text
    css_select("[data-testid=holding-options]").first.text.squish
  end

  test "the options section sits between Overview and Fundamentals and is open only when the ticker has rows" do
    account, provider = broker_account(positions: [ position ])
    nvda = holding(account: account, provider: provider, ticker: "NVDA", qty: 100)
    open_drawer(nvda)

    titles = css_select("details > summary").map { |summary| summary.text.squish }
    overview = titles.index { |title| title.include?(I18n.t("holdings.show.overview")) }
    options = titles.index { |title| title.include?(I18n.t("holdings.show.options")) }
    stock_data = titles.index { |title| title.include?(I18n.t("holdings.show.stock_data")) }
    assert overview && options && stock_data
    assert_equal [ overview, options, stock_data ], [ overview, options, stock_data ].sort
    assert_equal overview + 1, options
    assert_equal options + 1, stock_data
    assert_select "details[open] [data-testid=holding-options]", count: 1

    bare, bare_provider = broker_account(positions: [])
    msft = holding(account: bare, provider: bare_provider, ticker: "MSFT", qty: 5)
    open_drawer(msft)
    assert_select "[data-testid=holding-options]", count: 1
    assert_select "details[open] [data-testid=holding-options]", count: 0
  end

  test "only rows for this holding's ticker and account are listed, matched exactly" do
    mine, mine_provider = broker_account(name: "Mine", positions: [
      position, position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215"), position(symbol: "NV    261113P00100000", strike: "100")
    ])
    broker_account(name: "Other Brokerage", positions: [ position(symbol: "NVDA  261113C00230000", type: "CALL", strike: "230") ])
    nvda = holding(account: mine, provider: mine_provider, ticker: "NVDA", qty: 100)
    open_drawer(nvda)

    assert_select "[data-testid=holding-options-row]", count: 1
    assert_select "[data-testid=holding-options-row][data-account-id=?][data-contract=?]", mine.id, "NVDA  261113P00215000"
    assert_no_match(/AAPL|NV    261113|Other Brokerage|230000/, section_text)

    short = holding(account: mine, provider: mine_provider, ticker: "NV", qty: 1)
    open_drawer(short)
    assert_select "[data-testid=holding-options-row]", count: 1
    assert_select "[data-testid=holding-options-row][data-contract=?]", "NV    261113P00100000"
  end

  test "the ledger is a labelled scrollable semantic table without account or day P&L columns" do
    account, provider = broker_account(positions: [ position ])
    open_drawer(holding(account: account, provider: provider, ticker: "NVDA", qty: 100))

    assert_select "div.overflow-x-auto[role=region][tabindex='0'][aria-label] table[data-testid=holding-options-ledger]", count: 1
    assert_select "table[data-testid=holding-options-ledger] caption", count: 1
    headers = css_select("table[data-testid=holding-options-ledger] thead th[scope=col]").map { |th| th.text.squish }
    assert_equal 7, headers.size
    [ /Contract/, /Expiry/, /Qty/, /Mark/, /Total P&L/, /delta/i, /Evidence/ ].each_with_index { |pattern, index| assert_match pattern, headers[index] }
    assert_select "table[data-testid=holding-options-ledger] tr[data-testid=holding-options-row]", count: 1
    assert_includes section_text, "Day P&L unavailable - position change unknown"
    assert_select "[data-testid=holding-options-ledger] div, [data-testid=holding-options-ledger] article", count: 0
  end

  test "rows show the quote mark, signed total P&L, privacy masking and a subtotal from the group" do
    account, provider = broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215", qty: "1", price: "99", basis: "10") ])
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "12.40", ask: "12.60")
    open_drawer(holding(account: account, provider: provider, ticker: "AAPL", qty: 100))

    text = css_select("[data-testid=holding-options-row]").first.text.squish
    assert_includes text, "$12.50"
    assert_not_includes text, "$99.00", "the broker mark must never be shown as the price"
    assert_includes text, "+$250.00"
    assert_match(/as of/i, text)
    assert_select "[data-testid=holding-options-row] .privacy-sensitive", minimum: 2
    assert_match(/\$250\.00/, css_select("[data-testid=holding-options-subtotal]").first.text)
  end

  test "the subtotal is withheld with the existing cause when a row cannot be measured" do
    account, provider = broker_account(positions: [ position(price: "2", basis: nil) ])
    open_drawer(holding(account: account, provider: provider, ticker: "NVDA", qty: 100))

    subtotal = css_select("[data-testid=holding-options-subtotal]").first.text.squish
    assert_match(/—/, subtotal)
    assert_match(/missing a figure/, subtotal)
    assert_no_match(/\$0\.00/, subtotal)
  end

  test "a stale snapshot shows the desk banner, never the broker mark, and says Stale" do
    account, provider = broker_account(freshness: NOW - 40.hours, positions: [ position(price: "12.5") ])
    open_drawer(holding(account: account, provider: provider, ticker: "NVDA", qty: 100))

    assert_select "[data-testid=holding-options-source-banner]", text: /Broker snapshot is stale/
    text = css_select("[data-testid=holding-options-row]").first.text.squish
    assert_not_includes text, "$12.50"
    assert_includes text, "Stale"
    assert_match(/Synced .* ago/, text)
  end

  test "an empty readable snapshot says no open contracts for the ticker" do
    account, provider = broker_account(positions: [])
    open_drawer(holding(account: account, provider: provider, ticker: "NVDA", qty: 100))

    assert_select "[data-testid=holding-options-source-banner]", text: /No open option contracts/
    assert_select "[data-testid=holding-options-empty]", text: /No open option contracts for NVDA/
    assert_select "[data-testid=holding-options-ledger]", count: 0
    assert_select "[data-testid=holding-options-unavailable]", count: 0
  end

  test "an available source with no rows for this ticker also says no open contracts for it" do
    account, provider = broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215") ])
    open_drawer(holding(account: account, provider: provider, ticker: "NVDA", qty: 100))

    assert_select "[data-testid=holding-options-source-banner]", count: 0
    assert_select "[data-testid=holding-options-empty]", text: /No open option contracts for NVDA/
  end

  test "unavailable and stale sources with no rows never claim there are no open contracts" do
    { "unavailable" => [ NOW, "not-an-array", /Broker option data unavailable/ ],
      "no sync time" => [ nil, [], /Broker option data unavailable/ ],
      "stale" => [ NOW - 40.hours, [], /Broker snapshot is stale/ ] }.each do |label, (freshness, payload, banner)|
      account, provider = broker_account(freshness: freshness, raw_options_payload: payload)
      open_drawer(holding(account: account, provider: provider, ticker: "NVDA", qty: 100))

      assert_select "[data-testid=holding-options-source-banner]", text: banner, message: label
      assert_select "[data-testid=holding-options-unavailable]", count: 1, message: label
      assert_select "[data-testid=holding-options-empty]", count: 0, message: label
      assert_no_match(/No open option contracts/i, section_text, label)
    end
  end

  test "an account the desk will not scope renders only an unavailable note and never other accounts" do
    hidden, hidden_provider = broker_account(name: "Hidden Account", positions: [ position ])
    broker_account(name: "Visible Other", positions: [ position(symbol: "NVDA  261113C00230000", type: "CALL", strike: "230") ])
    nvda = holding(account: hidden, provider: hidden_provider, ticker: "NVDA", qty: 100)
    hidden.update_columns(status: "disabled")
    open_drawer(nvda)

    assert_select "[data-testid=holding-options-unavailable]", count: 1
    assert_select "[data-testid=holding-options-row]", count: 0
    assert_select "[data-testid=holding-options-ledger]", count: 0
    assert_select "[data-testid=holding-options-source-banner]", count: 0
    assert_no_match(/Visible Other|230000|215000/, section_text)
  end

  test "covered-call candidates and put exclusions are filtered to this ticker and account" do
    account, provider = broker_account(positions: [])
    other, = broker_account(name: "Other Shares", positions: [])
    nvda = holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    idea = Options::IdeaScanner::Idea.new(
      kind: :covered_call, account_id: account.id, account_name: account.name, underlying: "NVDA", contract: "NVDA261113C00230000",
      contract_symbol: "NVDA261113C00230000", expiration: EXPIRATION, dte: 29, strike: BigDecimal("230"), bid: BigDecimal("2.00"), ask: BigDecimal("2.20"),
      mid: BigDecimal("2.10"), delta: 0.21, iv: 0.4, open_interest: 100, credit_per_contract: BigDecimal("200"), contracts: 1, contracts_max: 3,
      annualized_yield_pct: BigDecimal("12.3"), called_away_price: BigDecimal("232"), distance_from_spot_pct: BigDecimal("5.9"), currency: "USD",
      quote_time: NOW - 5.minutes, flags: %i[no_basis_data earnings_unknown]
    )
    other_account_idea = idea.dup.tap { |copy| copy.account_id = other.id; copy.account_name = other.name; copy.contract = "NVDA261113C00999000" }
    other_underlying_idea = idea.dup.tap { |copy| copy.underlying = "AAPL"; copy.contract = "AAPL261113C00230000" }
    exclusion = Options::IdeaScanner::Exclusion.new(kind: :covered_call, account_id: account.id, account_name: account.name, underlying: "NVDA",
                                                    contract: "NVDA261113C00250000", option_type: "CALL", expiration: EXPIRATION, strike: BigDecimal("250"),
                                                    reasons: %i[insufficient_shares low_oi])
    other_exclusion = exclusion.dup.tap { |copy| copy.account_id = other.id; copy.account_name = other.name; copy.contract = "NVDA261113C00888000" }
    put_exclusion = Options::IdeaScanner::Exclusion.new(kind: :cash_needed_put, account_id: account.id, account_name: account.name, underlying: "NVDA",
                                                        contract: "NVDA261113P00215000", option_type: "PUT", expiration: EXPIRATION, strike: BigDecimal("215"),
                                                        reasons: %i[no_cash_data])
    other_put = put_exclusion.dup.tap { |copy| copy.account_id = other.id; copy.account_name = other.name; copy.contract = "NVDA261113P00777000" }
    wrong_put = put_exclusion.dup.tap { |copy| copy.underlying = "AAPL"; copy.contract = "AAPL261113P00215000" }
    scan = ->(ideas, exclusions) { Options::IdeaScanner::Result.new(ideas: ideas, exclusions: exclusions, candidates_count: ideas.size, joint_exposure_note: Options::IdeaScanner::JOINT_EXPOSURE_NOTE) }
    base = OptionsDesk.new(user: @owner, account_id: account.id, now: NOW).result
    stubbed = base.with(ideas: OptionsDesk::Ideas.new(covered_calls: scan.call([ idea, other_account_idea, other_underlying_idea ], [ exclusion, other_exclusion ]),
                                                      puts: scan.call([], [ put_exclusion, other_put, wrong_put ])))
    OptionsDesk.any_instance.stubs(:result).returns(stubbed)
    open_drawer(nvda)

    assert_select "[data-testid=holding-options-ideas]", count: 1
    assert_select "[data-testid=holding-options-covered-call-idea]", count: 1
    assert_select "[data-testid=holding-options-covered-call-exclusion]", count: 1
    assert_select "[data-testid=holding-options-puts-unavailable]", text: /Put screening unavailable - collateral not verified/
    text = section_text
    assert_includes text, "Research only"
    assert_includes text, "NVDA261113C00230000"
    assert_includes text, "NVDA261113P00215000"
    assert_no_match(/Other Shares|C00999000|C00888000|P00777000|AAPL/, text)
    assert_no_match BANNED, text
  end

  test "the section links to the full desk for this account and has no write or trade controls" do
    account, provider = broker_account(positions: [ position ])
    open_drawer(holding(account: account, provider: provider, ticker: "NVDA", qty: 100))

    assert_select "[data-testid=holding-options] a[href=?]", options_review_path(account: account.id), text: "Open full Options Desk"
    assert_select "[data-testid=holding-options] form, [data-testid=holding-options] button, [data-testid=holding-options] input, [data-testid=holding-options] select, [data-testid=holding-options] textarea", count: 0
    assert_no_match BANNED, section_text
  end

  test "account and contract text is escaped in the drawer" do
    account, provider = broker_account(name: "<img src=x onerror=alert(1)>", positions: [ position ])
    open_drawer(holding(account: account, provider: provider, ticker: "NVDA", qty: 100))

    assert_select "[data-testid=holding-options] img", count: 0
  end

  test "a holding in an account with no broker link shows no options section and never a broker-outage notice" do
    account = @owner.family.accounts.create!(name: "Manual Brokerage", balance: 1000, cash_balance: 0, currency: "USD", owner: @owner,
                                             status: "active", accountable: Investment.new(subtype: "brokerage"))
    security = Security.find_or_create_by!(ticker: "NVDA") { |record| record.name = "NVDA" }
    manual = Holding.create!(account: account, security: security, date: NOW.to_date, qty: 10, price: 1, amount: 10, currency: "USD")
    OptionsDesk.expects(:new).never
    open_drawer(manual)

    assert_select "[data-testid=holding-options]", count: 0
    assert_no_match(/Broker option data|open contracts may be missing/i, response.body)
  end

  test "an unrelated broker link elsewhere does not give a non-broker holding an options section" do
    broker_account(positions: [ position ])
    manual_account = @owner.family.accounts.create!(name: "Manual Two", balance: 1000, cash_balance: 0, currency: "USD", owner: @owner,
                                                    status: "active", accountable: Investment.new(subtype: "brokerage"))
    security = Security.find_or_create_by!(ticker: "NVDA") { |record| record.name = "NVDA" }
    manual = Holding.create!(account: manual_account, security: security, date: NOW.to_date, qty: 10, price: 1, amount: 10, currency: "USD")
    open_drawer(manual)

    assert_select "[data-testid=holding-options]", count: 0
    assert_no_match(/NVDA  261113P00215000/, response.body)
  end

  test "the drawer computes the options desk exactly once, scoped to the holding's account" do
    account, provider = broker_account(positions: [ position ])
    nvda = holding(account: account, provider: provider, ticker: "NVDA", qty: 100)
    real = OptionsDesk.new(user: @owner, account_id: account.id, now: NOW).result
    OptionsDesk.expects(:new).once.with(has_entries(account_id: account.id)).returns(stub(result: real))

    open_drawer(nvda)
    assert_select "[data-testid=holding-options-row]", count: 1
  end
end
