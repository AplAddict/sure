require "test_helper"

# Independent adversarial tests for the redesigned Options Desk page (GET /portfolio/options).
# Written from the binding contracts only (options-redesign-contract v2, options-desk-display-contract v1.1,
# options-holdings-contract). Nothing here reads the implementation: every assertion is a statement about the
# rendered response, with the approved read model (OptionsDesk) used as an oracle where counts are needed.
class OptionsDeskRedesignAdversarialTest < ActionDispatch::IntegrationTest
  NOW = Time.utc(2026, 10, 15, 15, 0)
  EXPIRATION = Date.new(2026, 11, 13)
  TOMORROW = Date.new(2026, 10, 16)
  BANNED = /cash-secured|safe|best|opportunity|top ideas|sell|buy now|trade now|execute|place order/i
  SIX_PHRASES = [ "Read-only research view", "No order capability", "Not investment or trading advice",
                  "Quote data may be delayed or indicative", "Model delta is an estimate", "Put collateral is not verified" ].freeze
  HEADERS = [ "Contract", "Account", "Expiry / DTE", "Qty", "Mark / basis", "Total P&L", "Model delta", "Evidence / as-of" ].freeze
  SUMMARY_HOOKS = %w[options-desk-summary options-desk-summary-total-pnl options-desk-summary-day-pnl
                     options-desk-summary-delta options-desk-summary-unreadable].freeze
  PUT_HEADING = "Put screening unavailable - collateral not verified".freeze

  setup do
    travel_to NOW
    @owner = users(:family_admin)
    @member = users(:family_member)
    @other_user = users(:empty)
  end

  teardown { travel_back }

  # ---------------------------------------------------------------- fixtures

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

  def occ(root, expiration, type, strike)
    format("%-6s%s%s%08d", root, expiration.strftime("%y%m%d"), type[0], (BigDecimal(strike.to_s) * 1000).to_i)
  end

  def position(root: "NVDA", type: "PUT", strike: "215", expiration: EXPIRATION, symbol: nil, qty: "1", price: "2", basis: "1", multiplier: "100", currency: "USD")
    symbol ||= occ(root, expiration, type, strike)
    { "instrument" => { "symbol" => symbol, "option_type" => type, "expiration_date" => expiration.to_s, "strike_price" => strike, "multiplier" => multiplier },
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

  # ---------------------------------------------------------------- readers

  def desk_root
    css_select("[data-testid=options-desk]").first
  end

  def desk_text
    desk_root.text.squish
  end

  def node(testid)
    css_select("[data-testid=#{testid}]").first
  end

  def ledger_rows
    css_select("[data-testid=options-desk-row]")
  end

  def row_for(contract)
    ledger_rows.find { |row| row["data-contract"] == contract }
  end

  def cells(row)
    row.xpath("./td|./th")
  end

  # Two accounts that both hold NVDA shares, with 45 regular + 5 MINI quotes per type: the "385 exclusions" shape.
  def flooded_ideas_fixture
    first, first_provider = broker_account(name: "First Shares", positions: [])
    second, second_provider = broker_account(name: "Second Shares", positions: [])
    holding(account: first, provider: first_provider, ticker: "NVDA", qty: 300)
    holding(account: second, provider: second_provider, ticker: "NVDA", qty: 300)
    (1..45).each do |index|
      quote(type: "CALL", strike: 250 + index)
      quote(type: "PUT", strike: 100 + index)
    end
    (1..5).each do |index|
      quote(type: "CALL", strike: 400 + index, contract_size: "MINI")
      quote(type: "PUT", strike: 50 + index, contract_size: "MINI")
    end
    [ first, second ]
  end

  def exclusion_count_from(row)
    row.text.squish[/(\d+)\s+contracts?/, 1].to_i
  end

  # ================================================================ (a) compact alert

  test "alert keeps all six required phrases in one compact strip with no bullet list" do
    get_desk

    assert_select "[data-testid=options-desk-alert]", count: 1
    alert = node("options-desk-alert")
    text = alert.text.squish
    SIX_PHRASES.each { |phrase| assert_includes text, phrase }
    assert_empty alert.css("ul, ol, li"), "the alert must not be a bullet list"
    assert_operator text.length, :<, 420, "the alert must stay compact: #{text.length} chars"
    assert_includes text, " · ", "the secondary phrases are one line separated by a middle dot"
    assert_no_match BANNED, text
  end

  test "alert phrases are visible text, not hidden by sr-only or hidden attributes" do
    get_desk

    alert = node("options-desk-alert")
    SIX_PHRASES.each do |phrase|
      holders = ([ alert ] + alert.css("*").to_a).select { |element| element.children.any? { |child| child.text? && child.text.include?(phrase) } }
      assert holders.any?, "#{phrase} must be rendered as text"
      holders.each do |holder|
        chain = [ holder ] + holder.ancestors.to_a.take_while { |ancestor| ancestor != alert.parent }
        assert chain.none? { |element| element["hidden"] || element["class"].to_s.split.include?("sr-only") || element["aria-hidden"] == "true" },
               "#{phrase} must not be hidden"
      end
    end
  end

  test "banned vocabulary is absent from every rendered string in the desk root even with ideas and exclusions" do
    account, provider = broker_account(positions: [ position(type: "CALL", strike: "230", qty: "-1") ])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    quote(type: "CALL", strike: 250)
    quote(type: "PUT", strike: 215)
    quote(type: "CALL", strike: 235, bid: "1.9", ask: "2.1")
    get_desk

    assert_select "[data-testid=options-desk-puts-unavailable]"
    assert_no_match BANNED, desk_text
    attributes = desk_root.css("*").flat_map { |element| %w[aria-label title alt placeholder].filter_map { |name| element[name] } }.join(" ")
    assert_no_match BANNED, attributes
  end

  test "banned vocabulary stays absent in the empty, stale and unavailable states" do
    get_desk
    assert_no_match BANNED, desk_text

    broker_account(positions: [])
    get_desk
    assert_no_match BANNED, desk_text

    SnaptradeAccount.update_all(last_holdings_sync: NOW - 40.hours)
    get options_review_path
    assert_no_match BANNED, desk_text
  end

  # ================================================================ (b) summary strip

  test "the summary strip exposes only the contract hooks and shows the four stats" do
    broker_account(positions: [ position ])
    quote
    get_desk

    assert_select "[data-testid=options-desk-summary]", count: 1
    assert_select "[data-testid=options-desk-summary-total-pnl]", count: 1
    assert_select "[data-testid=options-desk-summary-day-pnl]", count: 1
    assert_select "[data-testid=options-desk-summary-delta]", count: 1
    assert_select "[data-testid=options-desk-summary-unreadable]", count: 0
    hooks = desk_root.css("[data-testid^=options-desk-summary]").map { |element| element["data-testid"] }.uniq
    assert_empty hooks - SUMMARY_HOOKS, "unexpected summary hooks: #{(hooks - SUMMARY_HOOKS).inspect}"
    summary = node("options-desk-summary").text.squish
    assert_match(/Total P&L/, summary)
    assert_match(/Model delta/, summary)
    assert_match(/Contracts/i, summary)
    assert_match(/Expiring/i, summary)
  end

  test "the summary strip drops the retired stat cards for indicative, unavailable and current marks" do
    broker_account(positions: [ position ])
    get_desk

    leaves = node("options-desk-summary").css("*").select { |element| element.element_children.empty? }.map { |element| element.text.squish }
    [ "Indicative", "Unavailable", "Current marks", "Open contracts" ].each do |retired|
      assert_not_includes leaves, retired, "#{retired} is no longer a stat card label"
    end
  end

  test "total P&L unavailable keeps the headline to a dash and puts the cause in small secondary text" do
    broker_account(positions: [ position(basis: nil) ])
    get_desk

    total = node("options-desk-summary-total-pnl")
    headline = total.css(".text-xl")
    assert_operator headline.size, :<=, 1
    headline.each { |element| assert_equal "—", element.text.squish, "the headline carries only the dash" }
    causes = total.css(".text-xs")
    assert_operator causes.size, :>=, 1
    assert causes.any? { |element| element.text.squish.length > 3 }, "a cause must sit in a text-xs element"
    assert_empty total.css(".text-2xl, .text-3xl, h1, h2, h3")
  end

  test "total P&L with a value shows the signed money at most once at headline size" do
    broker_account(positions: [ position(type: "CALL", strike: "215", root: "AAPL", price: "99", basis: "10") ])
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "12.40", ask: "12.60")
    get_desk

    total = node("options-desk-summary-total-pnl")
    assert_match(/\+\$250\.00/, total.text)
    assert_operator total.css(".text-xl").size, :<=, 1
  end

  test "partial delta: one contract with a delta and one with a wide quote shows a labelled partial, never an unlabelled total" do
    broker_account(positions: [ position, position(root: "AAPL", type: "CALL", strike: "215", price: "2", basis: "1") ])
    quote
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "1.00", ask: "3.00")
    get_desk

    delta = node("options-desk-summary-delta")
    text = delta.text.squish
    assert_match(/Partial/, text)
    assert_match(/1 of 2 contracts included/, text)
    assert_match(/-\s?35\.7/, text, "the partial sum of the one qualified delta is shown")
    assert_match(/estimate/i, text)
    assert_match(/only/i, text, "the wording must say the figure covers only contracts with a qualified delta")
    figures = delta.css(".privacy-sensitive")
    assert figures.any?, "the partial figure keeps privacy masking"
    assert figures.none? { |figure| figure.text.squish.empty? }
  end

  test "complete delta total is shown without Partial when every contract has a delta" do
    broker_account(positions: [ position, position(root: "AAPL", type: "CALL", strike: "215") ])
    quote
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "6.40", ask: "6.60")
    get_desk

    text = node("options-desk-summary-delta").text.squish
    assert_no_match(/Partial/i, text)
    assert_no_match(/\d+ of \d+ contracts included/, text)
    assert_match(/24\.7/, text, "-35.7 + 60.5 is the complete total")
    assert node("options-desk-summary-delta").css(".privacy-sensitive").any?
  end

  test "no delta on any contract shows a dash with a cause and no figure" do
    broker_account(positions: [ position ])
    get_desk

    delta = node("options-desk-summary-delta")
    text = delta.text.squish
    assert_includes text, "—"
    assert_no_match(/Partial/i, text)
    assert_no_match(/\d+ of \d+ contracts included/, text)
    assert_empty delta.css(".privacy-sensitive")
    assert delta.css(".text-xs").any? { |element| element.text.squish.length > 3 }, "the cause is small secondary text"
    assert_operator delta.css(".text-xl").size, :<=, 1
  end

  test "an unreadable source withholds the partial delta and says totals are withheld" do
    broker_account(positions: [ position ])
    broker_account(raw_options_payload: "not-an-array")
    quote
    get_desk

    delta = node("options-desk-summary-delta").text.squish
    assert_no_match(/Partial/i, delta)
    assert_no_match(/35\.7/, delta)
    assert_no_match(/of \d+ contracts included/, delta)
    assert_includes delta, "—"
    assert_select "[data-testid=options-desk-summary-unreadable]", text: /1 broker source\(s\) unreadable - totals withheld/
    assert_includes node("options-desk-summary-total-pnl").text, "—"
  end

  test "mixed currencies never produce a total or a partial figure that hides the currency problem" do
    broker_account(positions: [ position ], currency: "USD")
    broker_account(positions: [ position(root: "AAPL", type: "CALL", strike: "215", currency: "CAD") ], currency: "CAD")
    quote
    get_desk

    assert_includes node("options-desk-summary-total-pnl").text, "—"
    assert_no_match(/\+\$|-\$/, node("options-desk-summary-total-pnl").text)
  end

  test "the contracts stat carries the mark breakdown and the expiring stat carries the past-expiry count" do
    broker_account(positions: [
      position,
      position(root: "AAPL", type: "CALL", strike: "215", price: "2", basis: "1"),
      position(root: "MSFT", type: "CALL", strike: "300", expiration: Date.new(2026, 10, 20)),
      position(root: "TSLA", type: "PUT", strike: "200", expiration: Date.new(2026, 10, 14))
    ])
    quote
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "1.00", ask: "3.00")
    get_desk

    text = node("options-desk-summary").text.squish
    assert_match(/\b4\b/, text)
    assert_match(/1 current marks?/, text)
    assert_match(/1 indicative/, text)
    assert_match(/1 past expiry/, text)
  end

  test "past expiry is not mentioned when no contract is past expiry" do
    broker_account(positions: [ position ])
    get_desk

    assert_no_match(/past expiry/i, node("options-desk-summary").text)
  end

  test "an empty source renders a summary with no fabricated figures" do
    broker_account(positions: [])
    get_desk

    summary = node("options-desk-summary").text
    assert_no_match(/Partial/i, summary)
    assert_no_match(/\$\d/, summary)
    assert_no_match(/missing a figure/, summary)
  end

  # ================================================================ (c) day P&L

  test "the ledger has exactly the eight redesigned column headers in order and no Day P&L column" do
    broker_account(positions: [ position ])
    get_desk

    headers = css_select("table[data-testid=options-desk-ledger] thead th[scope=col]").map { |th| th.text.squish }
    assert_equal HEADERS, headers
    assert_empty css_select("table[data-testid=options-desk-ledger] thead th").reject { |th| th["scope"] == "col" }
    assert_no_match(/Day P&L/, css_select("table[data-testid=options-desk-ledger]").first.text)
  end

  test "position change unknown appears exactly once on the page, in the summary day P&L line, with no number" do
    broker_account(positions: [
      position, position(strike: "210"),
      position(root: "AAPL", type: "CALL", strike: "215", price: "12.5", basis: "10"),
      position(root: "MSFT", type: "PUT", strike: "300")
    ])
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "12.40", ask: "12.60")
    get_desk

    assert_operator ledger_rows.size, :>=, 4
    assert_equal 1, desk_root.text.scan(/position change unknown/).size
    day = node("options-desk-summary-day-pnl").text.squish
    assert_includes day, "position change unknown"
    assert_no_match(/\d/, day)
    assert_no_match(/\$/, day)
    ledger_rows.each { |row| assert_no_match(/position change unknown/, row.text) }
    css_select("[data-testid=options-desk-group-total]").each { |group| assert_no_match(/position change unknown/, group.text) }
  end

  test "the day P&L line is small secondary text rather than a stat card" do
    broker_account(positions: [ position ])
    get_desk

    day = node("options-desk-summary-day-pnl")
    assert_empty day.css(".text-xl, .text-2xl, .text-lg")
    assert_match(/Day P&L unavailable - position change unknown/, day.text.squish)
    assert_match(/Day P&L/, day.text)
  end

  test "an empty source keeps a single day P&L line and never a day figure" do
    broker_account(positions: [])
    get_desk

    assert_operator desk_root.text.scan(/position change unknown/).size, :<=, 1
    assert_no_match(/Day P&L[^a-z]*[+-]?\$/, desk_text)
  end

  # ================================================================ (d) contract cell

  test "the contract cell leads with a human label and keeps the exact OCC string as a small second line" do
    put = occ("NVDA", EXPIRATION, "PUT", "215")
    call = occ("AAPL", EXPIRATION, "CALL", "230")
    broker_account(positions: [ position, position(root: "AAPL", type: "CALL", strike: "230") ])
    get_desk

    {
      put => "NVDA $215 Put",
      call => "AAPL $230 Call"
    }.each do |contract, label|
      row = row_for(contract)
      assert row, "row for #{contract} must keep the exact OCC string in data-contract"
      first_cell = cells(row).first
      text = first_cell.text.squish
      assert_includes text, label
      assert_includes text, contract.squish
      assert_operator text.index(label), :<, text.index(contract.squish), "the human label comes first"
      holder = first_cell.css("*").select { |element| element.text.squish == contract.squish && element.element_children.empty? }.last
      assert holder, "the OCC string sits in its own element"
      lineage = [ holder ] + holder.ancestors.take_while { |ancestor| ancestor != first_cell.parent }
      assert lineage.any? { |element| element["class"].to_s.match?(/\btext-xs\b|\btext-\[\d+px\]/) }, "the OCC line is small text"
      assert lineage.any? { |element| element["class"].to_s.split.include?("font-mono") }, "the OCC line is monospace"
    end
  end

  test "an unrecognised currency renders the strike as a plain number" do
    broker_account(positions: [ position(currency: "ZZZ") ])
    quote(currency: "ZZZ")
    get_desk

    first = cells(ledger_rows.first).first.text.squish
    assert_includes first, "NVDA 215 Put"
    assert_not_includes first, "$215"
  end

  test "a row whose strike is missing falls back to the OCC string alone" do
    contract = occ("NVDA", EXPIRATION, "PUT", "215")
    broker_account(positions: [ position.deep_merge("instrument" => { "strike_price" => nil }) ])
    get_desk

    row = row_for(contract)
    assert row
    first = cells(row).first.text.squish
    assert_includes first, contract.squish
    assert_no_match(/\$\s?\d/, first)
    assert_no_match(/\bPut\b/, first)
    assert_no_match(/\bCall\b/, first)
  end

  test "a row with no recognisable underlying or option type makes the source unreadable rather than a half-labelled row" do
    broker_account(positions: [ position(symbol: "261113P00215000") ])
    get_desk

    assert_select "[data-testid=options-desk-row]", count: 0
    assert_select "[data-testid=options-desk-empty]", count: 0
    assert_select "[data-testid=options-desk-source-banner]", text: /unavailable/i
  end

  test "hostile contract strings and account names are escaped on the wire" do
    hostile_contract = %(NVDA  261113P00215000"><script>alert(1)</script>)
    hostile_account = %(Acct "><script>alert(2)</script><img src=x onerror=alert(3)>)
    broker_account(name: hostile_account, positions: [ position(symbol: hostile_contract) ])
    get_desk

    body = response.body
    assert_not_includes body, "<script>alert(1)"
    assert_not_includes body, "<script>alert(2)"
    assert_not_includes body, "<img src=x onerror=alert(3)>"
    assert_not_includes body, %(215000"><script)
    assert_includes body, "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert_includes body, "&lt;script&gt;alert(2)&lt;/script&gt;"
    assert_empty css_select("script").select { |script| script.text.include?("alert(") }
    assert_empty css_select("img[onerror]")
    row = ledger_rows.first
    assert_equal hostile_contract, row["data-contract"], "the attribute round-trips the exact string"
  end

  test "hostile account names stay escaped in the account-qualified idea rows too" do
    hostile = %(<img src=x onerror=alert(9)> "quoted" 'single')
    account, provider = broker_account(name: hostile, positions: [])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    quote(type: "CALL", strike: 250)
    quote(type: "PUT", strike: 215)
    get_desk

    assert_not_includes response.body, "<img src=x onerror=alert(9)>"
    assert_includes response.body, "&lt;img src=x onerror=alert(9)&gt;"
    assert_empty css_select("img[onerror]")
  end

  # ================================================================ (e) side pill

  test "a short quantity shows a Short pill and a long quantity shows a Long pill" do
    short_contract = occ("NVDA", EXPIRATION, "PUT", "215")
    long_contract = occ("AAPL", EXPIRATION, "CALL", "215")
    broker_account(positions: [ position(qty: "-2"), position(root: "AAPL", type: "CALL", strike: "215", qty: "3") ])
    get_desk

    short = row_for(short_contract)
    long = row_for(long_contract)
    assert_match(/-2/, short.text)
    assert(short.css("*").any? { |element| element.element_children.empty? && element.text.squish == "Short" }, "Short pill")
    assert(short.css("*").none? { |element| element.element_children.empty? && element.text.squish == "Long" })
    assert_match(/\b3\b/, long.text)
    assert(long.css("*").any? { |element| element.element_children.empty? && element.text.squish == "Long" }, "Long pill")
    assert(long.css("*").none? { |element| element.element_children.empty? && element.text.squish == "Short" })
  end

  test "the side pill sits in the quantity cell next to the signed quantity" do
    broker_account(positions: [ position(qty: "-2") ])
    get_desk

    qty_cell = cells(ledger_rows.first)[3]
    assert_match(/-2/, qty_cell.text)
    assert_match(/Short/, qty_cell.text)
    assert_no_match(/Long/, qty_cell.text)
  end

  # ================================================================ (f) delta unavailable reasons

  test "each unavailable delta shows a dash plus a short reason label and never a number or zero" do
    near = occ("NVDA", TOMORROW, "PUT", "215")
    one_sided = occ("AAPL", EXPIRATION, "CALL", "215")
    broker_only = occ("MSFT", EXPIRATION, "PUT", "300")
    broker_account(positions: [
      position(expiration: TOMORROW),
      position(root: "AAPL", type: "CALL", strike: "215"),
      position(root: "MSFT", type: "PUT", strike: "300")
    ])
    quote(expiration: TOMORROW)
    quote(underlying: "AAPL", type: "CALL", strike: 215, bid: "0", ask: "2.20")
    get_desk

    {
      near => "Too close to expiry",
      one_sided => "No two-sided market",
      broker_only => "No direct quote"
    }.each do |contract, label|
      row = row_for(contract)
      assert row, "row #{contract}"
      delta = cells(row)[6].text.squish
      assert_match(/\A—\s*#{Regexp.escape(label)}\z/, delta)
      assert_no_match(/\d/, delta)
      assert_no_match(/\$0/, delta)
    end
  end

  test "an unsolvable or otherwise unknown delta reason falls back to Unavailable" do
    contract = occ("NVDA", EXPIRATION, "PUT", "215")
    broker_account(positions: [ position ])
    quote(underlying_price: nil)
    get_desk

    delta = cells(row_for(contract))[6].text.squish
    assert_match(/\A—\s*Unavailable\z/, delta)
  end

  test "a row with a delta shows the number, masked for privacy, and no reason label" do
    contract = occ("NVDA", EXPIRATION, "PUT", "215")
    broker_account(positions: [ position ])
    quote
    get_desk

    cell = cells(row_for(contract))[6]
    assert_match(/-\s?35\.7|-35/, cell.text)
    assert cell.css(".privacy-sensitive").any?
    assert cell.css(".tabular-nums").any?
    assert_no_match(/Too close|No two-sided|No direct|Unavailable/, cell.text)
  end

  test "delta reasons are never fabricated into a figure for a long or short position alike" do
    broker_account(positions: [ position(qty: "-1", expiration: TOMORROW), position(root: "AAPL", type: "CALL", strike: "215", qty: "-4") ])
    quote(expiration: TOMORROW)
    get_desk

    ledger_rows.each do |row|
      delta = cells(row)[6].text.squish
      assert_no_match(/\d/, delta)
      assert_match(/\A—/, delta)
    end
  end

  # ================================================================ (g) expiry order

  test "within an underlying group rows are ordered nearest expiry first across accounts" do
    late = Date.new(2026, 11, 20)
    near = Date.new(2026, 10, 23)
    broker_account(name: "Alpha Late", positions: [ position(expiration: late), position(expiration: EXPIRATION) ])
    broker_account(name: "Beta Near", positions: [ position(expiration: near), position(expiration: EXPIRATION, strike: "210") ])
    get_desk

    groups = css_select("tbody").select { |body| body.at_css("[data-testid=options-desk-group-total]") }
    assert_equal 1, groups.size
    expirations = groups.first.css("[data-testid=options-desk-row]").map { |row| row["data-contract"][/\d{6}(?=[CP]\d{8}\z)/] }
    assert_equal 4, expirations.size
    assert_equal expirations.sort, expirations, "nearest expiry first: #{expirations.inspect}"
  end

  test "expiry ordering is applied per underlying group independently" do
    broker_account(positions: [
      position(expiration: Date.new(2026, 11, 20)), position(expiration: Date.new(2026, 10, 23)),
      position(root: "AAPL", type: "CALL", strike: "215", expiration: Date.new(2026, 12, 18)),
      position(root: "AAPL", type: "CALL", strike: "220", expiration: Date.new(2026, 10, 30))
    ])
    get_desk

    css_select("tbody").each do |body|
      next unless body.at_css("[data-testid=options-desk-group-total]")

      expirations = body.css("[data-testid=options-desk-row]").map { |row| row["data-contract"][/\d{6}(?=[CP]\d{8}\z)/] }
      assert_equal expirations.sort, expirations
    end
  end

  # ================================================================ (h) exclusion summary

  test "a flooded chain renders a bounded number of summarised rows in each section" do
    flooded_ideas_fixture
    get_desk

    %w[options-desk-covered-calls options-desk-puts-unavailable].each do |testid|
      section = node(testid)
      assert section, testid
      rows = section.css("[data-account-id]")
      assert_operator rows.size, :<, 30, "#{testid} renders #{rows.size} account rows"
      assert_operator section.css("li").size, :<, 60, "#{testid} must not list hundreds of contracts"
    end
    assert_operator desk_root.css("[data-account-id]").size, :<, 80
  end

  test "summarised exclusion rows state a contract count and the reason label" do
    first, second = flooded_ideas_fixture
    get_desk

    oracle = OptionsDesk.new(user: @owner, now: NOW).result.ideas
    reason_labels = I18n.t("options_reviews.desk.reasons").values
    rows = css_select("[data-testid=options-desk-puts-unavailable] [data-account-id]")
    rows.each do |row|
      assert_match(/\d+\s+contracts?/, row.text.squish)
    end
    assert rows.any? { |row| exclusion_count_from(row) >= 10 }, "a flooded group states a large count"
    assert rows.any? { |row| reason_labels.any? { |label| row.text.include?(label) } }
    assert_includes rows.map(&:text).join(" "), "Collateral not verified"
    [ first, second ].each do |account|
      account_rows = rows.select { |row| row["data-account-id"] == account.id }
      assert account_rows.any?, "account #{account.name} has its own put exclusion rows"
      assert_includes account_rows.map { |row| row.text }.join(" "), account.name
      expected = oracle.puts.exclusions.count { |exclusion| exclusion.account_id == account.id }
      assert_equal expected, account_rows.sum { |row| exclusion_count_from(row) }, "counts per account add up to the model's exclusions"
    end
  end

  test "covered-call exclusions are summarised per account with counts that match the model and never pool accounts" do
    first, second = flooded_ideas_fixture
    get_desk

    oracle = OptionsDesk.new(user: @owner, now: NOW).result.ideas.covered_calls
    exclusion_rows = css_select("[data-testid=options-desk-covered-call-exclusion]")
    assert exclusion_rows.any?
    assert_operator exclusion_rows.size, :<, 30
    reason_labels = I18n.t("options_reviews.desk.reasons").values
    exclusion_rows.each do |row|
      assert_includes [ first.id, second.id ], row["data-account-id"]
      assert_match(/\d+\s+contracts?/, row.text.squish)
      assert reason_labels.any? { |label| row.text.include?(label) }, "reason label in #{row.text.squish}"
    end
    [ first, second ].each do |account|
      account_rows = exclusion_rows.select { |row| row["data-account-id"] == account.id }
      expected = oracle.exclusions.count { |exclusion| exclusion.account_id == account.id }
      assert_equal expected, account_rows.sum { |row| exclusion_count_from(row) }, "#{account.name}: counted on its own, not pooled"
      assert_includes account_rows.map(&:text).join(" "), account.name
    end
    total = oracle.exclusions.size
    assert_empty exclusion_rows.select { |row| exclusion_count_from(row) == total }, "no single row may pool both accounts' exclusions"
  end

  test "MINI quotes never appear anywhere in the ideas sections or their counts" do
    flooded_ideas_fixture
    get_desk

    oracle = OptionsDesk.new(user: @owner, now: NOW).result.ideas
    regular_calls = OptionQuote.where(option_type: "CALL", contract_size: "REGULAR").count
    regular_puts = OptionQuote.where(option_type: "PUT", contract_size: "REGULAR").count
    per_account_calls = css_select("[data-testid=options-desk-covered-call-exclusion]").group_by { |row| row["data-account-id"] }
                                                                                             .transform_values { |rows| rows.sum { |row| exclusion_count_from(row) } }
    per_account_calls.each_value { |count| assert_operator count, :<=, regular_calls }
    per_account_puts = css_select("[data-testid=options-desk-puts-unavailable] [data-account-id]").group_by { |row| row["data-account-id"] }
                                                                                                   .transform_values { |rows| rows.sum { |row| exclusion_count_from(row) } }
    per_account_puts.each_value { |count| assert_operator count, :<=, regular_puts }
    assert_equal oracle.puts.exclusions.group_by(&:account_id).transform_values(&:size), per_account_puts
    OptionQuote.where(contract_size: "MINI").pluck(:contract_symbol).each do |symbol|
      assert_not_includes response.body, symbol
    end
  end

  test "the put section keeps its exact heading, no candidate wording and per-account rows" do
    first, second = flooded_ideas_fixture
    get_desk

    section = node("options-desk-puts-unavailable")
    headings = section.css("h1, h2, h3, h4, h5, h6").map { |heading| heading.text.squish }
    assert_includes headings, PUT_HEADING
    assert_no_match(/candidate/i, section.text)
    assert_no_match(/cash-secured/i, section.text)
    assert_match(/collateral/i, section.text)
    [ first, second ].each { |account| assert_select "[data-testid=options-desk-puts-unavailable] [data-account-id=?]", account.id }
    assert_empty section.css("[data-testid=options-desk-covered-call-idea]")
  end

  test "covered-call candidates still appear only under the account that holds the shares" do
    holder, holder_provider = broker_account(name: "Holds Shares", positions: [])
    broker_account(name: "No Shares", positions: [])
    holding(account: holder, provider: holder_provider, ticker: "NVDA", qty: 300)
    quote(type: "CALL", strike: 235, bid: "1.9", ask: "2.1")
    quote(type: "CALL", strike: 240, bid: "1.0", ask: "1.2")
    get_desk

    section = node("options-desk-covered-calls")
    assert_match(/Research only/, section.text)
    assert_includes section.text.squish, Options::IdeaScanner::JOINT_EXPOSURE_NOTE
    ideas = css_select("[data-testid=options-desk-covered-call-idea]")
    assert ideas.any?, "a candidate in the delta band is still listed"
    assert_equal [ holder.id ], ideas.map { |idea| idea["data-account-id"] }.uniq
    assert_empty css_select("[data-testid=options-desk-covered-calls] [data-account-id]").reject { |row| row["data-account-id"] == holder.id }
    assert_no_match(/No Shares/, section.text)
  end

  test "a small exclusion set is still summarised by reason set with a count and an account name" do
    account, provider = broker_account(name: "Small Account", positions: [])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    quote(type: "PUT", strike: 215)
    quote(type: "PUT", strike: 210)
    get_desk

    rows = css_select("[data-testid=options-desk-puts-unavailable] [data-account-id]").select { |row| row["data-account-id"] == account.id }
    assert rows.any?
    assert_equal 2, rows.sum { |row| exclusion_count_from(row) }
    rows.each { |row| assert_includes row.text, "Small Account" }
  end

  test "the exclusion summary helper returns account, reasons and count triples without pooling accounts" do
    build = lambda do |account_id, name, reasons, index|
      Options::IdeaScanner::Exclusion.new(kind: :cash_needed_put, account_id: account_id, account_name: name, underlying: "NVDA",
                                          contract: "NVDA261113P#{format('%08d', 100_000 + index)}", option_type: "PUT",
                                          expiration: EXPIRATION, strike: BigDecimal("100"), reasons: reasons)
    end
    exclusions = (1..3).map { |index| build.call("acct-a", "Account A", %i[no_cash_data], index) } +
                 (4..5).map { |index| build.call("acct-b", "Account B", %i[no_cash_data], index) } +
                 [ build.call("acct-b", "Account B", %i[insufficient_shares], 6) ]
    names = OptionsDeskHelper.instance_methods.grep(/exclusion_summary/)
    assert_not_empty names, "an exclusion summary helper (options_desk_exclusion_summary) must exist"

    summary = ApplicationController.helpers.public_send(names.first, exclusions)
    assert_equal [ [ "Account A", 3 ], [ "Account B", 1 ], [ "Account B", 2 ] ], summary.map { |name, _reasons, count| [ name, count ] }.sort
    summary.each { |_name, reasons, _count| assert_not_empty Array(reasons) }
  end

  # ================================================================ (i) removed sections

  test "the page has exactly Summary, Contracts and Ideas sections with no Attention or Exposure section" do
    account, provider = broker_account(positions: [ position ])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    quote
    get_desk

    keys = css_select("[data-reports-sortable-target=section]").map { |section| section["data-section-key"] }
    assert_equal %w[contracts ideas summary], keys.sort
    titles = css_select("[data-reports-sortable-target=section] h2").map { |heading| heading.text.squish }
    assert_equal 1, titles.count { |title| title.match?(/Summary/i) }, titles.inspect
    assert titles.none? { |title| title.match?(/Attention/i) }
    assert titles.none? { |title| title.match?(/Exposure/i) }
    all_elements = desk_root.css("*").select { |element| element.element_children.empty? }
    assert all_elements.none? { |element| element.text.squish == "Attention" }
    assert all_elements.none? { |element| element.text.squish.match?(/\AExposure\z/) }
    assert_select "[data-section-key=summary] [data-testid=options-desk-summary]", count: 1
    assert_select "[data-section-key=contracts] [data-testid=options-desk-ledger]", count: 1
    assert_select "[data-section-key=ideas] [data-testid=options-desk-covered-calls]", count: 1
    assert_select "[data-testid=options-desk-summary-delta]", count: 1, message: "delta appears once, not repeated in an Exposure card"
  end

  test "saved section preferences with the retired attention and exposure keys do not break the page" do
    broker_account(positions: [ position ])
    @owner.update!(preferences: (@owner.preferences || {}).merge(
      "investments_options_section_order" => %w[exposure attention contracts summary ideas],
      "investments_options_collapsed_sections" => { "attention" => true, "exposure" => true, "summary" => false }
    ))
    get_desk

    keys = css_select("[data-reports-sortable-target=section]").map { |section| section["data-section-key"] }
    assert_equal %w[contracts ideas summary], keys.sort
    assert_equal %w[contracts summary], keys.first(2)
  end

  test "section order and collapse preferences still apply to the remaining sections" do
    broker_account(positions: [ position ])
    @owner.update_investment_sections("options", order: %w[ideas contracts summary], collapsed: { "summary" => true })
    get_desk

    assert_equal "ideas", css_select("[data-reports-sortable-target=section]").first["data-section-key"]
  end

  # ================================================================ (j) legacy link

  test "the legacy view link is a plain text link inside the desk root, not a button" do
    broker_account(positions: [ position ])
    get_desk

    links = css_select("[data-testid=options-desk] a[href='/portfolio/options/legacy']")
    assert_equal 1, links.size
    link = links.first
    assert_match(/Open legacy view/, link.text.squish)
    assert_empty link.css("button")
    assert_empty link.ancestors("button")
    assert_not_equal "button", link["role"]
    assert_no_match(/\bbg-/, link["class"].to_s, "no filled background: a quiet link")
    assert_nil link["data-turbo-method"]
    assert_equal legacy_options_review_path, link["href"]
    assert_empty css_select("button").select { |button| button.text.include?("legacy") }
    assert_select "[data-testid=options-desk] a[href=?]", legacy_options_review_path, text: /Open legacy view/
  end

  test "the legacy link survives the empty and unavailable states and the legacy page still works" do
    get_desk
    assert_select "[data-testid=options-desk] a[href='/portfolio/options/legacy']", count: 1

    get legacy_options_review_path
    assert_response :success
    assert_select "[data-testid=options-legacy-banner]", text: /Legacy options review/
    assert_select "a[href=?]", options_review_path
  end

  test "the desk still has no forms, inputs, write links or credentials after the redesign" do
    account, provider = broker_account(positions: [ position ])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    quote(type: "CALL", strike: 250)
    get_desk

    assert_empty desk_root.css("form, input, select, textarea, button[type=submit]")
    assert_empty desk_root.css("a[data-turbo-method], a[data-method]")
    assert_no_match(/password|consumer_key|client_id|api key|credential|robinhood/i, desk_root.text)
  end

  # ================================================================ (k) source states

  test "a stale snapshot shows the banner and still never shows the broker mark" do
    broker_account(freshness: NOW - 40.hours, positions: [ position(price: "12.5", basis: "10") ])
    get_desk

    assert_select "[data-testid=options-desk-source-banner]", count: 1, text: /Broker snapshot is stale/
    assert_not_includes ledger_rows.first.text, "$12.50"
  end

  test "an unreadable source shows unavailable and totals withheld and no partial delta" do
    broker_account(raw_options_payload: "not-an-array")
    get_desk

    assert_select "[data-testid=options-desk-source-banner]", text: /Broker option data unavailable/
    assert_select "[data-testid=options-desk-empty]", count: 0
    assert_select "[data-testid=options-desk-unavailable]", count: 1
    assert_select "[data-testid=options-desk-row]", count: 0
    assert_no_match(/No open option contracts/, desk_text)
    assert_no_match(/Partial/i, node("options-desk-summary-delta").text)

    broker_account(positions: [ position ])
    get options_review_path
    assert_select "[data-testid=options-desk-summary-unreadable]", text: /totals withheld/
  end

  test "a readable empty source shows the empty state and no table" do
    broker_account(positions: [])
    get_desk

    assert_select "[data-testid=options-desk-empty]", count: 1
    assert_select "[data-testid=options-desk-source-banner]", text: /No open option contracts/
    assert_select "[data-testid=options-desk-ledger]", count: 0
    assert_select "[data-testid=options-desk-unavailable]", count: 0
  end

  test "an invalid account shows only the unavailable-account state with no rows, ledger, summary figures or ideas rows" do
    broker_account(positions: [ position ])
    get_desk(account: SecureRandom.uuid)

    assert_select "[data-testid=options-desk-invalid-scope]", count: 1, text: /Selected account is unavailable/
    assert_select "[data-testid=options-desk-row]", count: 0
    assert_select "[data-testid=options-desk-ledger]", count: 0
    assert_select "[data-testid=options-desk-source-banner]", count: 0
    assert_no_match(/NVDA/, desk_text)
    assert_select "[data-testid=options-desk-alert]", count: 1
  end

  test "an available source never renders a source banner and the ledger keeps its semantics" do
    broker_account(positions: [ position ])
    get_desk

    assert_select "[data-testid=options-desk-source-banner]", count: 0
    assert_select "div.overflow-x-auto[role=region][tabindex='0'][aria-label] table[data-testid=options-desk-ledger] caption", count: 1
    assert_select "table[data-testid=options-desk-ledger] tr[data-testid=options-desk-group-total]", count: 1
    assert_select "table[data-testid=options-desk-ledger] tr[data-testid=options-desk-row][data-account-id][data-contract]", count: 1
    assert_select "[data-testid=options-desk-ledger] article", count: 0
  end

  test "the ledger keeps nowrap cells and privacy masking on position-size figures" do
    broker_account(positions: [ position(qty: "2") ])
    quote
    get_desk

    row = ledger_rows.first
    assert row.css(".privacy-sensitive").size >= 2, "quantity and delta/P&L stay masked"
    assert row.css("[class*=whitespace-nowrap]").any?
    assert_match(/as of .* ET/, row.text.squish)
  end

  # ================================================================ (l) privacy and access

  test "a member with no shared accounts sees none of the owner's contracts, accounts or labels" do
    secret, = broker_account(name: "Owner Secret Brokerage", positions: [ position(root: "NVDA"), position(root: "MSFT", type: "CALL", strike: "300") ])
    quote
    sign_in @member
    get options_review_path

    assert_response :success
    assert_select "[data-testid=options-desk-row]", count: 0
    assert_no_match(/Owner Secret Brokerage|NVDA|MSFT/, response.body)
    assert_not_includes response.body, "261113P00215000"
    assert_not_includes response.body, secret.id
  end

  test "a shared account exposes only that account's contracts, human labels and ideas to the member" do
    broker_account(name: "Owner Private", positions: [ position(root: "MSFT", type: "PUT", strike: "200") ])
    shared, shared_provider = broker_account(name: "Shared With Member", positions: [ position(root: "AAPL", type: "CALL", strike: "215") ])
    holding(account: shared, provider: shared_provider, ticker: "AAPL", qty: 300)
    AccountShare.create!(account: shared, user: @member, permission: "read_only")
    quote(underlying: "AAPL", type: "CALL", strike: 215)
    sign_in @member
    get options_review_path

    assert_response :success
    assert_select "[data-testid=options-desk-row]", count: 1
    assert_select "[data-testid=options-desk-row][data-account-id=?]", shared.id
    assert_no_match(/Owner Private|MSFT/, response.body)
    assert_includes cells(ledger_rows.first).first.text.squish, "AAPL $215 Call"
    assert_equal [ shared.id ], css_select("[data-testid=options-desk-covered-calls] [data-account-id], [data-testid=options-desk-puts-unavailable] [data-account-id]").map { |row| row["data-account-id"] }.uniq
  end

  test "hostile account params fail closed with no rows and none of the hidden account's data" do
    broker_account(name: "Visible Owner Account", positions: [ position(root: "AAPL", type: "CALL", strike: "215") ])
    hidden, = broker_account(owner: @other_user, family: @other_user.family, name: "Hidden Stranger Account", positions: [ position(root: "TSLA", type: "PUT", strike: "200") ])
    hostile = [
      { account: hidden.id }, { account: SecureRandom.uuid }, { account: "not-an-id" }, { account: [ hidden.id ] },
      { account: { id: hidden.id } }, { account: "' OR '1'='1" }, { account: "#{hidden.id}%00" }, { account: "9" * 400 },
      { account: "<script>alert(1)</script>" }
    ]
    hostile.each do |params|
      get_desk(**params)
      assert_select "[data-testid=options-desk-invalid-scope]", count: 1
      assert_select "[data-testid=options-desk-row]", count: 0
      assert_select "[data-testid=options-desk-ledger]", count: 0
      assert_no_match(/AAPL|TSLA|Visible Owner Account|Hidden Stranger Account/, desk_text)
      assert_not_includes response.body, "<script>alert(1)"
    end
  end

  test "a valid account scope narrows the summary, ledger and ideas to that account" do
    first, first_provider = broker_account(name: "Scoped One", positions: [ position(root: "AAPL", type: "CALL", strike: "215") ])
    second, second_provider = broker_account(name: "Scoped Two", positions: [ position(root: "MSFT", type: "PUT", strike: "300") ])
    holding(account: first, provider: first_provider, ticker: "NVDA", qty: 300)
    holding(account: second, provider: second_provider, ticker: "NVDA", qty: 300)
    quote(type: "PUT", strike: 215)
    get_desk(account: first.id)

    assert_select "[data-testid=options-desk-row]", count: 1
    assert_select "[data-testid=options-desk-row][data-account-id=?]", first.id
    assert_no_match(/MSFT|Scoped Two/, desk_text)
    assert_empty css_select("[data-account-id]").select { |element| element["data-account-id"] == second.id }
  end

  test "anonymous visitors are redirected from the desk and the legacy view" do
    get options_review_path
    assert_redirected_to new_session_path
    get legacy_options_review_path
    assert_redirected_to new_session_path
    get options_review_path, params: { account: "anything" }
    assert_redirected_to new_session_path
  end

  # ================================================================ (m) robustness

  test "an unknown currency ZZZ never raises and renders unavailable money" do
    broker_account(positions: [ position(currency: "ZZZ"), position(root: "AAPL", type: "CALL", strike: "215", currency: "ZZZ") ])
    quote(currency: "ZZZ")
    get_desk

    assert_select "[data-testid=options-desk-row]", count: 2
    total = node("options-desk-summary-total-pnl").text
    assert_includes total, "—"
    assert_no_match(/\$|ZZZ\s*\d/, total)
  end

  test "a negative broker mark is unavailable rather than a credit or a loss figure" do
    contract = occ("NVDA", EXPIRATION, "PUT", "215")
    broker_account(positions: [ position(price: "-2.50", basis: "1") ])
    get_desk

    row = row_for(contract)
    assert row
    text = row.text.squish
    assert_no_match(/2\.50/, text)
    assert_no_match(/-\$|\+\$/, text)
    assert_match(/—/, text)
    assert_includes node("options-desk-summary-total-pnl").text, "—"
    assert_match(/\A—/, cells(row)[6].text.squish)
  end

  test "malformed numeric fields never raise and are shown as unavailable" do
    broker_account(positions: [ position(qty: "1", price: "abc", basis: "NaN").deep_merge("instrument" => { "strike_price" => "x" }) ])
    get_desk

    assert_response :success
    assert_select "[data-testid=options-desk-alert]", count: 1
  end
end
