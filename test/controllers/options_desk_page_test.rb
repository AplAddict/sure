require "test_helper"

# The Options Desk page (GET /portfolio/options). Display rules are the binding
# options-desk display contract: research-only, account-scoped, fail closed.
class OptionsDeskPageTest < ActionDispatch::IntegrationTest
  NOW = Time.utc(2026, 10, 15, 15, 0)
  EXPIRATION = Date.new(2026, 11, 13)
  BANNED = /cash-secured|safe|best|opportunity|top ideas|sell|buy now|trade now|execute|place order/i

  setup do
    travel_to NOW
    @owner = users(:family_admin)
    @member = users(:family_member)
    @other_user = users(:empty)
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

  def get_desk(**params)
    sign_in @owner
    get options_review_path, params: params
    assert_response :success
  end

  def desk_text
    css_select("[data-testid=options-desk]").first.text.squish
  end

  test "the persistent alert states the research-only limits and avoids recommendation vocabulary" do
    get_desk

    assert_select "[data-testid=options-desk]"
    assert_select "[data-testid=options-desk-alert]", count: 1
    text = css_select("[data-testid=options-desk-alert]").first.text.squish
    [ "Read-only research view", "No order capability", "Not investment or trading advice", "Quote data may be delayed or indicative",
      "Model delta is an estimate", "Put collateral is not verified" ].each do |phrase|
      assert_includes text, phrase
    end
    assert_no_match BANNED, text
  end

  test "recommendation vocabulary is absent from the whole desk even with ideas and exclusions on screen" do
    account, provider = broker_account(positions: [ position(symbol: "NVDA  261113C00230000", type: "CALL", strike: "230", qty: "-1") ])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    quote(type: "CALL", strike: 250)
    quote(type: "PUT", strike: 215)
    get_desk

    assert_select "[data-testid=options-desk-puts-unavailable]"
    assert_no_match BANNED, desk_text
  end

  test "a member sees only the accounts shared with them and never another member's private account" do
    broker_account(name: "Private Owner Account", positions: [ position(symbol: "MSFT  261113P00200000", strike: "200") ])
    shared, = broker_account(name: "Shared Desk Account", positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215") ])
    broker_account(owner: @other_user, family: @other_user.family, name: "Stranger Account", positions: [ position(symbol: "TSLA  261113P00200000", strike: "200") ])
    AccountShare.create!(account: shared, user: @member, permission: "read_only")

    sign_in @member
    get options_review_path
    assert_response :success
    assert_select "[data-testid=options-desk-row]", count: 1
    assert_select "[data-testid=options-desk-row][data-account-id=?]", shared.id
    assert_select "[data-testid=options-desk-row][data-contract=?]", "AAPL  261113C00215000"
    assert_no_match(/Private Owner Account|MSFT|Stranger Account|TSLA/, response.body)

    sign_in @owner
    get options_review_path
    assert_select "[data-testid=options-desk-row]", count: 2
    assert_no_match(/Stranger Account|TSLA/, response.body)
  end

  test "a valid ?account narrows to that account only" do
    first, = broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215") ])
    broker_account(positions: [ position(symbol: "MSFT  261113P00200000", strike: "200") ])

    get_desk(account: first.id)

    assert_select "[data-testid=options-desk-row]", count: 1
    assert_select "[data-testid=options-desk-row][data-account-id=?]", first.id
    assert_no_match(/MSFT/, desk_text)
  end

  test "an inaccessible, unknown or malformed ?account fails closed without falling back to all accounts" do
    broker_account(name: "Visible Owner Account", positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215") ])
    hidden, = broker_account(owner: @other_user, family: @other_user.family, name: "Hidden Stranger Account", positions: [ position(symbol: "TSLA  261113P00200000", strike: "200") ])

    [ { account: hidden.id }, { account: SecureRandom.uuid }, { account: "not-an-id" }, { account: [ hidden.id ] }, { account: { id: hidden.id } } ].each do |params|
      get_desk(**params)

      assert_select "[data-testid=options-desk-invalid-scope]", text: /Selected account is unavailable/
      assert_select "[data-testid=options-desk-row]", count: 0
      assert_select "[data-testid=options-desk-ledger]", count: 0
      assert_select "[data-testid=options-desk-group-total]", count: 0
      assert_no_match(/AAPL|TSLA|Visible Owner Account|Hidden Stranger Account/, desk_text)
    end
  end

  test "the ledger is a labelled, focusable, horizontally scrollable semantic table" do
    broker_account(positions: [ position ])
    get_desk

    assert_select "div.overflow-x-auto[tabindex='0'][aria-label] [data-testid=options-desk-ledger]", count: 1
    assert_select "table[data-testid=options-desk-ledger] caption", count: 1
    headers = css_select("table[data-testid=options-desk-ledger] thead th[scope=col]").map { |th| th.text.squish }
    assert_equal 9, headers.size
    [ /Contract/, /Account/, /Expiry/, /Qty/, /Mark/, /Total P&L/, /Day P&L/, /delta/i, /Evidence/ ].each_with_index do |pattern, index|
      assert_match pattern, headers[index]
    end
    assert_select "table[data-testid=options-desk-ledger] tr[data-testid=options-desk-row]", count: 1
    assert_select "table[data-testid=options-desk-ledger] tr[data-testid=options-desk-group-total]", count: 1
    assert_select "[data-testid=options-desk-ledger] div, [data-testid=options-desk-ledger] article", count: 0
  end

  test "ledger rows show the quote mark with as-of, signed total P&L and a subtotal per underlying" do
    account, = broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215", qty: "1", price: "99", basis: "10") ])
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "12.40", ask: "12.60")
    get_desk

    row = css_select("[data-testid=options-desk-row]").first
    text = row.text.squish
    assert_equal account.id, row["data-account-id"]
    assert_includes text, "$12.50"
    assert_not_includes text, "$99.00", "the broker mark must never be shown as the price"
    assert_includes text, "+$250.00"
    assert_match(/as of/i, text)
    assert_match(/Current/, text)
    assert_match(/\$250\.00/, css_select("[data-testid=options-desk-group-total]").first.text)
    assert_match(/\$250\.00/, css_select("[data-testid=options-desk-summary-total-pnl]").first.text)
  end

  test "a short position's P&L rises when the mark falls" do
    broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215", qty: "-1", price: "99", basis: "10") ])
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "7.40", ask: "7.60")
    get_desk

    assert_includes css_select("[data-testid=options-desk-row]").first.text.squish, "+$250.00"
  end

  test "day P&L is always unavailable with the position-change wording, never zero" do
    broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215", price: "12.5", basis: "10") ])
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "12.40", ask: "12.60")
    get_desk

    css_select("[data-testid=options-desk-row]").each do |row|
      assert_includes row.text.squish, "Unavailable - position change unknown"
    end
    summary_day = css_select("[data-testid=options-desk-summary-day-pnl]").first.text.squish
    assert_includes summary_day, "Unavailable - position change unknown"
    assert_no_match(/\$0\.00/, summary_day)
  end

  test "a true zero renders as $0.00 while a missing figure renders as an em dash with a cause" do
    _account, provider = broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215", price: "10", basis: "10") ])
    get_desk
    assert_includes css_select("[data-testid=options-desk-row]").first.text.squish, "$0.00"

    provider.update!(raw_options_payload: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215", price: "10", basis: nil) ])
    get options_review_path
    text = css_select("[data-testid=options-desk-row]").first.text.squish
    assert_match(/—/, text)
    assert_match(/cost basis/i, text)
    assert_no_match(/\$0\.00/, text)
  end

  test "a stale snapshot never shows the broker mark and says Stale with the sync time instead of the reason" do
    broker_account(freshness: NOW - 40.hours, positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215", price: "12.5", basis: "10") ])
    get_desk

    assert_select "[data-testid=options-desk-source-banner]", text: /Broker snapshot is stale/
    text = css_select("[data-testid=options-desk-row]").first.text.squish
    assert_not_includes text, "$12.50"
    assert_includes text, "Stale"
    assert_match(/Synced .* ago/, text)
    assert_no_match(/No mark/i, text)
  end

  test "indicative marks are shown as indicative and never totalled" do
    broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "215", price: "12.5", basis: "10") ])
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "1.00", ask: "3.00")
    get_desk

    text = css_select("[data-testid=options-desk-row]").first.text.squish
    assert_includes text, "Indicative"
    assert_not_includes text, "+$"
    assert_select "[data-testid=options-desk-summary-total-pnl]", text: /—/
  end

  test "source banner states follow the read model and never appear when available" do
    broker_account(positions: [ position ])
    get_desk
    assert_select "[data-testid=options-desk-source-banner]", count: 0

    SnaptradeAccount.update_all(last_holdings_sync: NOW - 40.hours)
    get options_review_path
    assert_select "[data-testid=options-desk-source-banner]", text: /Broker snapshot is stale/

    SnaptradeAccount.update_all(last_holdings_sync: NOW, raw_options_payload: "not-an-array")
    get options_review_path
    assert_select "[data-testid=options-desk-source-banner]", text: /Broker option data unavailable/
  end

  test "an empty snapshot is a known state with its own banner and empty state" do
    broker_account(positions: [])
    get_desk

    assert_select "[data-testid=options-desk-source-banner]", text: /No open option contracts/
    assert_select "[data-testid=options-desk-empty]", count: 1
    assert_select "[data-testid=options-desk-row]", count: 0
    assert_select "[data-testid=options-desk-ledger]", count: 0
  end

  test "unreadable sources are counted beside the totals and totals are withheld" do
    broker_account(positions: [ position ])
    broker_account(raw_options_payload: "not-an-array")
    get_desk

    assert_select "[data-testid=options-desk-summary-unreadable]", text: /1 broker source\(s\) unreadable - totals withheld/
    assert_select "[data-testid=options-desk-summary-total-pnl]", text: /—/
  end

  test "an unrecognised broker currency code never raises and renders unavailable" do
    broker_account(positions: [ position(currency: "ZZZ") ])
    quote(currency: "ZZZ")
    get_desk

    assert_select "[data-testid=options-desk-row]", count: 1
    assert_select "[data-testid=options-desk-summary-total-pnl]", text: /—/
    assert_no_match(/\$|ZZZ\s*\d/, css_select("[data-testid=options-desk-summary-total-pnl]").first.text)
  end

  test "evidence as-of is shown only when a direct quote backs the mark" do
    quote(quote_time: NOW - 7.minutes, last_trade_at: NOW - 7.minutes)
    broker_account(positions: [ position ])
    get_desk
    backed = css_select("[data-testid=options-desk-row]").first.text.squish
    assert_match(/as of/, backed)

    OptionQuote.update_all(session_date: Date.new(2026, 10, 14))
    get_desk
    rejected = css_select("[data-testid=options-desk-row]").first.text.squish
    assert_no_match(/as of/, rejected)
  end

  test "put exclusions are grouped and bounded so a long chain cannot flood the page" do
    account, provider = broker_account(positions: [])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    (1..60).each { |index| quote(type: "PUT", strike: 100 + index) }
    get_desk

    section = css_select("[data-testid=options-desk-puts-unavailable]").first
    assert section
    assert_operator css_select("[data-testid=options-desk-puts-unavailable] li[data-account-id]").size, :<=, 25
    assert_match(/more contract/, section.text)
  end

  test "summary unavailable values keep the cause small and secondary" do
    broker_account(positions: [ position(basis: nil) ])
    get_desk

    total = css_select("[data-testid=options-desk-summary-total-pnl]").first
    assert_equal 1, total.css("span.text-xl").size
    assert_equal "—", total.css("span.text-xl").first.text.strip
    assert_operator total.css("span.text-xs").size, :>=, 1
    day = css_select("[data-testid=options-desk-summary-day-pnl]").first
    assert_match(/position change unknown/, day.text)
  end

  test "an unreadable or missing source never renders the no-open-contracts empty state" do
    get_desk
    assert_select "[data-testid=options-desk-empty]", count: 0
    assert_select "[data-testid=options-desk-source-banner]", text: /unavailable/i
    assert_select "[data-testid=options-desk-unavailable]", count: 1

    broker_account(raw_options_payload: "not-an-array")
    get_desk
    assert_select "[data-testid=options-desk-empty]", count: 0
    assert_select "[data-testid=options-desk-unavailable]", count: 1
    assert_no_match(/No open option contracts/, desk_text)
  end

  test "a readable empty source still renders the no-open-contracts empty state" do
    broker_account(raw_options_payload: [])
    get_desk

    assert_select "[data-testid=options-desk-empty]", count: 1
    assert_select "[data-testid=options-desk-unavailable]", count: 0
  end

  test "an invalid account scope shows only the unavailable-account message, not a source banner" do
    get_desk(account: SecureRandom.uuid)

    assert_select "[data-testid=options-desk-invalid-scope]", count: 1
    assert_select "[data-testid=options-desk-source-banner]", count: 0
    assert_select "[data-testid=options-desk-empty]", count: 0
  end

  test "an account with a late-sorting symbol still appears when another account overflows the cap" do
    big, big_provider = broker_account(name: "Overflow Account", positions: [])
    ("AA".."BE").each do |ticker|
      holding(account: big, provider: big_provider, ticker: ticker, qty: 300)
      quote(underlying: ticker, type: "PUT", strike: 50)
    end
    small, small_provider = broker_account(name: "Late Symbol Account", positions: [])
    holding(account: small, provider: small_provider, ticker: "ZZZZ", qty: 300)
    quote(underlying: "ZZZZ", type: "PUT", strike: 50)
    get_desk

    section = "[data-testid=options-desk-puts-unavailable]"
    assert_select "#{section} [data-account-id=?]", small.id
    assert_match(/Overflow Account/, css_select(section).first.text)
    assert_match(/more group/, css_select(section).first.text)
  end

  test "position-size derived figures are masked in privacy mode" do
    broker_account(positions: [ position(symbol: "NVDA  261113P00215000", qty: "2") ])
    quote(type: "PUT", strike: 215)
    get_desk

    ledger_delta = css_select("[data-testid=options-desk-row] td.font-mono").map { |cell| cell.css(".tabular-nums") }.flatten
    assert(ledger_delta.any? { |node| node["class"].to_s.include?("privacy-sensitive") })
    summary_delta = css_select("[data-testid=options-desk-summary-delta] .tabular-nums").first
    assert_includes summary_delta["class"], "privacy-sensitive" if summary_delta
  end

  test "as-of times name the New York zone" do
    quote
    broker_account(positions: [ position ])
    get_desk

    assert_match(/as of .* ET/, css_select("[data-testid=options-desk-row]").first.text.squish)
  end

  test "an empty readable source does not claim a contract is missing a figure" do
    broker_account(raw_options_payload: [])
    get_desk

    assert_no_match(/missing a figure/, css_select("[data-testid=options-desk-summary-total-pnl]").first.text)
  end

  test "model delta is labelled as an estimate and the total carries the contract wording" do
    broker_account(positions: [ position(symbol: "NVDA  261113P00215000", qty: "1") ])
    quote(type: "PUT", strike: 215)
    get_desk

    assert_select "[data-testid=options-desk-summary-delta]", text: /Model delta estimate \(share-equivalent, all accounts shown\)/
    assert_select "table[data-testid=options-desk-ledger] thead th", text: /Model delta/
  end

  test "put screening is an explicit unavailable section that lists exclusions and never claims collateral" do
    account, provider = broker_account(positions: [])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    quote(type: "PUT", strike: 215)
    get_desk

    section = css_select("[data-testid=options-desk-puts-unavailable]").first
    assert section
    assert_includes section.text.squish, "Put screening unavailable - collateral not verified"
    assert_select "[data-testid=options-desk-puts-unavailable] [data-account-id=?]", account.id
    assert_match(/collateral/i, section.text)
    assert_no_match(/cash-secured/i, section.text)
  end

  test "covered-call candidates and exclusions are account-qualified and never pooled" do
    first, first_provider = broker_account(name: "First Shares", positions: [])
    second, second_provider = broker_account(name: "Second Shares", positions: [])
    holding(account: first, provider: first_provider, ticker: "NVDA", qty: 300)
    holding(account: second, provider: second_provider, ticker: "NVDA", qty: 100)
    quote(type: "CALL", strike: 250)
    get_desk

    assert_select "[data-testid=options-desk-covered-calls]", count: 1
    entries = css_select("[data-testid=options-desk-covered-call-idea], [data-testid=options-desk-covered-call-exclusion]")
    assert_equal [ first.id, second.id ].sort, entries.map { |entry| entry["data-account-id"] }.uniq.sort
    assert_match(/Research only/, css_select("[data-testid=options-desk-covered-calls]").first.text)
  end

  test "a covered-call candidate shows its flags and reasons and the exclusion shows why it was excluded" do
    idea = Options::IdeaScanner::Idea.new(
      kind: :covered_call, account_id: "acct-1", account_name: "Shares Account", underlying: "NVDA", contract: "NVDA261113C00230000",
      contract_symbol: "NVDA261113C00230000", expiration: EXPIRATION, dte: 29, strike: BigDecimal("230"), bid: BigDecimal("2.00"), ask: BigDecimal("2.20"),
      mid: BigDecimal("2.10"), delta: 0.21, iv: 0.4, open_interest: 100, credit_per_contract: BigDecimal("200"), contracts: 1, contracts_max: 3,
      annualized_yield_pct: BigDecimal("12.3"), called_away_price: BigDecimal("232"), distance_from_spot_pct: BigDecimal("5.9"), currency: "USD",
      quote_time: NOW - 5.minutes, flags: %i[no_basis_data earnings_unknown]
    )
    exclusion = Options::IdeaScanner::Exclusion.new(kind: :covered_call, account_id: "acct-2", account_name: "Thin Account", underlying: "NVDA",
                                                    contract: "NVDA261113C00250000", option_type: "CALL", expiration: EXPIRATION, strike: BigDecimal("250"),
                                                    reasons: %i[insufficient_shares low_oi])
    put_exclusion = Options::IdeaScanner::Exclusion.new(kind: :cash_needed_put, account_id: "acct-1", account_name: "Shares Account", underlying: "NVDA",
                                                        contract: "NVDA261113P00215000", option_type: "PUT", expiration: EXPIRATION, strike: BigDecimal("215"),
                                                        reasons: %i[no_cash_data])
    scan = ->(ideas, exclusions) { Options::IdeaScanner::Result.new(ideas: ideas, exclusions: exclusions, candidates_count: ideas.size, joint_exposure_note: Options::IdeaScanner::JOINT_EXPOSURE_NOTE) }
    base = OptionsDesk.new(user: @owner, now: NOW).result
    stubbed = base.with(ideas: OptionsDesk::Ideas.new(covered_calls: scan.call([ idea ], [ exclusion ]), puts: scan.call([], [ put_exclusion ])))
    OptionsDesk.any_instance.stubs(:result).returns(stubbed)
    get_desk

    candidate = css_select("[data-testid=options-desk-covered-call-idea]").first
    assert_equal "acct-1", candidate["data-account-id"]
    assert_includes candidate.text, "Shares Account"
    assert_includes candidate.text, "NVDA261113C00230000"
    assert_match(/basis/i, candidate.text)
    assert_match(/earnings/i, candidate.text)
    excluded = css_select("[data-testid=options-desk-covered-call-exclusion]").first
    assert_equal "acct-2", excluded["data-account-id"]
    assert_includes excluded.text, "Thin Account"
    assert_match(/shares/i, excluded.text)
    assert_match(/open interest/i, excluded.text)
    put_row = css_select("[data-testid=options-desk-puts-unavailable] [data-account-id=acct-1]").first
    assert_match(/collateral/i, put_row.text)
    assert_select "[data-testid=options-desk-puts-unavailable] [data-testid=options-desk-covered-call-idea]", count: 0
  end

  test "account and contract text is escaped" do
    broker_account(name: "<img src=x onerror=alert(1)>", positions: [ position ])
    get_desk

    assert_not_includes response.body, "<img src=x onerror=alert(1)>"
    assert_includes response.body, "&lt;img src=x onerror=alert(1)&gt;"
  end

  test "the desk has no forms, inputs, trade controls, credentials or broker-app references" do
    account, provider = broker_account(positions: [ position ])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    quote(type: "CALL", strike: 250)
    get_desk

    root = css_select("[data-testid=options-desk]").first
    assert_empty root.css("form, input, select, textarea, button[type=submit]")
    assert_empty root.css("a[data-turbo-method], a[data-method]")
    assert_no_match(/password|consumer_key|client_id|api key|credential|robinhood/i, root.text)
  end

  test "the desk links to the legacy view and the legacy view links back" do
    broker_account(positions: [ position ])
    get_desk

    assert_select "a[href=?]", legacy_options_review_path, text: /Open legacy view/
    get legacy_options_review_path
    assert_response :success
    assert_select "[data-testid=options-legacy-banner]", text: /Legacy options review/
    assert_select "a[href=?]", options_review_path
  end

  test "the desk sections are draggable and keep the persisted summary and contracts keys" do
    broker_account(positions: [ position ])
    get_desk

    keys = css_select("[data-reports-sortable-target=section]").map { |node| node["data-section-key"] }
    assert_equal %w[summary attention contracts exposure ideas].sort, keys.sort
    assert_select "[data-section-key=summary] [data-testid=options-desk-summary]"
    assert_select "[data-section-key=contracts] [data-testid=options-desk-ledger]"
    assert_select "[data-section-key=ideas] [data-testid=options-desk-covered-calls]"

    @owner.update_investment_sections("options", order: %w[contracts summary], collapsed: { "summary" => true })
    get options_review_path
    assert_response :success
    assert_equal "contracts", css_select("[data-reports-sortable-target=section]").first["data-section-key"]
  end

  test "an anonymous visitor cannot reach the desk or the legacy view" do
    get options_review_path
    assert_redirected_to new_session_path
    get legacy_options_review_path
    assert_redirected_to new_session_path
  end
end
