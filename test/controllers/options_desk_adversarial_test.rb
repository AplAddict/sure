require "test_helper"

class OptionsDeskAdversarialTest < ActionDispatch::IntegrationTest
  NOW = Time.utc(2026, 10, 15, 15, 0)
  EXPIRATION = Date.new(2026, 11, 13)
  LEGACY_PATH = "/portfolio/options/legacy"
  BANNED_COPY = [
    "cash-secured", "safe", "best", "opportunity", "top ideas", "sell",
    "buy now", "trade now", "execute", "place order"
  ].freeze
  REQUIRED_ALERT = [
    "Read-only research view",
    "No order capability",
    "Not investment or trading advice",
    "Quote data may be delayed or indicative",
    "Model delta is an estimate",
    "Put collateral is not verified"
  ].freeze

  setup do
    ensure_tailwind_build
    travel_to NOW
    @owner = users(:family_admin)
    @member = users(:family_member)
    @other_user = users(:empty)
  end

  teardown { travel_back }

  test "unshared family member never sees owner contract account quantity or pnl on the desk" do
    account, contract = private_owner_book
    sign_in @member
    get options_review_path
    assert_response :success
    assert_no_owner_leak(response.body, account: account, contract: contract)
  end

  test "unshared family member never sees owner contract account quantity or pnl on the legacy route" do
    account, contract = private_owner_book
    sign_in @member
    get LEGACY_PATH
    assert_response :success
    assert_no_owner_leak(response.body, account: account, contract: contract)
  end

  test "a shared account becomes visible to the member while unshared siblings stay hidden" do
    hidden, hidden_contract = private_owner_book(name: "HiddenDeskBrokerageZXQ")
    shared, = broker_account(positions: [ position(symbol: "AAPL  261113C00250000", type: "CALL", strike: "250") ])
    AccountShare.create!(account: shared, user: @member, permission: "read_only")

    sign_in @member
    get options_review_path
    assert_response :success
    assert_match "AAPL  261113C00250000", response.body
    assert_match shared.name, response.body
    assert_no_owner_leak(response.body, account: hidden, contract: hidden_contract)
  end

  test "a user in a different family sees nothing from the owner desk" do
    account, contract = private_owner_book
    sign_in @other_user

    get options_review_path
    assert_response :success
    assert_no_owner_leak(response.body, account: account, contract: contract)
    assert_select "[data-testid=options-desk-row]", count: 0
  end

  test "hostile account query params render selected-account unavailable with zero rows and no fallback" do
    account, contract = private_owner_book
    outsider, = broker_account(owner: @other_user, family: @other_user.family,
                               positions: [ position(symbol: "MSFT  261113P00200000", strike: "200") ])
    sign_in @owner

    hostile_account_params(hidden_id: outsider.id).each do |params|
      get options_review_path, params: params
      assert_response :success
      assert_match "Selected account is unavailable", response.body
      assert_select "[data-testid=options-desk-row]", count: 0
      refute_match(/#{Regexp.escape(contract)}/, desk_markup.presence || response.body)
      refute_match(/#{account.id}/, desk_markup)
    end
  end

  test "no query param widens desk scope to a hidden account" do
    account, contract = private_owner_book
    sign_in @member

    [
      { account: account.id },
      { account_id: account.id },
      { user_id: @owner.id },
      { family_id: @owner.family_id }
    ].each do |params|
      get options_review_path, params: params
      assert_response :success
      assert_no_owner_leak(response.body, account: account, contract: contract)
    end
  end

  test "no query param widens legacy scope to a hidden account" do
    account, contract = private_owner_book
    sign_in @member

    [
      { account: account.id },
      { account_id: account.id },
      { user_id: @owner.id },
      { family_id: @owner.family_id }
    ].each do |params|
      get LEGACY_PATH, params: params
      assert_response :success
      assert_no_owner_leak(response.body, account: account, contract: contract)
    end
  end

  test "xss in account name contract and underlying is escaped in the desk html" do
    script_name = "<script>alert(1)</script>"
    attr_name = '"><img src=x onerror=alert(1)>'
    xss_contract = "NVDA  261113P00215000<script>alert(1)</script>"
    broker_account(name: script_name, positions: [ position(symbol: xss_contract) ])
    broker_account(name: attr_name, positions: [ position(symbol: "AAPL  261113C00250000", type: "CALL", strike: "250") ])
    sign_in @owner

    get options_review_path
    assert_response :success
    body = response.body
    refute_match(%r{<script>alert\(1\)</script>}, body)
    refute_match(/<img src=x onerror=alert\(1\)>/, body)
    assert_match(/&lt;script&gt;/, body)
    assert_match(/onerror=alert\(1\)/, body)
  end

  test "persistent alert has required research-only phrases and desk root bans trade vocabulary and write controls" do
    broker_account(positions: [ position ])
    sign_in @owner
    get options_review_path
    assert_response :success

    assert_select "[data-testid=options-desk]"
    alert = css_select("[data-testid=options-desk-alert]").first
    assert alert, "missing options-desk-alert"
    REQUIRED_ALERT.each { |phrase| assert_match(/#{Regexp.escape(phrase)}/, alert.text) }

    markup = desk_markup
    BANNED_COPY.each { |word| refute_match(/#{Regexp.escape(word)}/i, markup) }

    assert_select "[data-testid=options-desk] form[method=post], [data-testid=options-desk] form[method=POST]", count: 0
    assert_select "[data-testid=options-desk] button[type=submit]", count: 0
    assert_select "[data-testid=options-desk] input[type=submit]", count: 0
    assert_select "[data-testid=options-desk] input[type=password]", count: 0
    assert_select "[data-testid=options-desk] input[name*='token']", count: 0
    assert_select "[data-testid=options-desk] input[name*='api']", count: 0
    assert_select "[data-testid=options-desk] input[name*='password']", count: 0
  end

  test "true zero mark and basis render dollar zero pnl while nil basis and day pnl stay unavailable" do
    zero_account, = broker_account(name: "ZeroDesk", positions: [ position(price: "0", basis: "0") ])
    nil_account, = broker_account(name: "NilBasisDesk", positions: [ position(symbol: "AAPL  261113P00150000", strike: "150", price: "2", basis: nil) ])
    sign_in @owner
    get options_review_path
    assert_response :success

    zero_row = row_for(account_id: zero_account.id)
    assert_match(/\$0\.00/, zero_row)
    assert_match(/Unavailable/i, zero_row)
    assert_match(/position change unknown/i, zero_row)

    nil_row = row_for(account_id: nil_account.id)
    assert_match(/—|&mdash;|&#8212;|Unavailable/i, nil_row)
    refute_match(/\$0\.00/, nil_row)
    assert_match(/position change unknown/i, nil_row)

    day = css_select("[data-testid=options-desk-summary-day-pnl]").first
    assert day, "missing options-desk-summary-day-pnl"
    assert_match(/Unavailable/i, day.text)
    assert_match(/position change unknown/i, day.text)
    refute_match(/\$[\d,]*\d/, day.text)
    refute_match(/\b0(?:\.0+)?\b/, day.text)
  end

  test "stale snapshot shows the source banner with stale wording" do
    broker_account(freshness: NOW - SnaptradeAccount::SNAPSHOT_STALE_AFTER - 1.second, positions: [ position ])
    sign_in @owner
    get options_review_path
    assert_response :success

    banner = css_select("[data-testid=options-desk-source-banner]").first
    assert banner, "missing options-desk-source-banner"
    assert_match(/Broker snapshot is stale/, banner.text)
  end

  test "unreadable payload shows unavailable banner totals withheld and no summary total" do
    broker_account(positions: [ position ])
    broker_account(name: "BrokenDesk", raw_options_payload: "not-an-array")
    sign_in @owner
    get options_review_path
    assert_response :success

    banner = css_select("[data-testid=options-desk-source-banner]").first
    assert banner, "missing options-desk-source-banner"
    assert_match(/Broker option data unavailable/, banner.text)

    unreadable = css_select("[data-testid=options-desk-summary-unreadable]").first
    assert unreadable, "missing options-desk-summary-unreadable"
    assert_match(/totals withheld/i, unreadable.text)
    assert_match(/unreadable/i, unreadable.text)

    total = css_select("[data-testid=options-desk-summary-total-pnl]").first
    assert total, "missing options-desk-summary-total-pnl"
    refute_match(/\$[\d,]+(?:\.\d{2})?/, total.text)
  end

  test "empty readable payload shows the empty state without error styling" do
    broker_account(raw_options_payload: [])
    sign_in @owner
    get options_review_path
    assert_response :success

    empty = css_select("[data-testid=options-desk-empty]").first
    assert empty, "missing options-desk-empty"
    assert_match(/No open option contracts/, empty.text)
    refute_match(/destructive|error/i, empty["class"].to_s)

    banner = css_select("[data-testid=options-desk-source-banner]").first
    assert banner, "missing options-desk-source-banner"
    assert_match(/No open option contracts/, banner.text)
    refute_match(/Broker option data unavailable/, banner.text)
  end

  test "mixed currencies blank currency and negative marks never pool a summary total" do
    broker_account(positions: [ position(price: "2", basis: "1") ])
    broker_account(currency: "CAD", positions: [ position(symbol: "AAPL  261113P00150000", strike: "150", currency: "CAD", price: "2", basis: "1") ])
    sign_in @owner
    get options_review_path
    assert_response :success
    total = css_select("[data-testid=options-desk-summary-total-pnl]").first
    assert total, "missing options-desk-summary-total-pnl"
    refute_match(/\$[\d,]+(?:\.\d{2})?/, total.text)

    _, blank_provider = broker_account(name: "BlankFxDesk", positions: [ position(symbol: "MSFT  261113P00200000", strike: "200", currency: "") ])
    blank_provider.update_columns(currency: nil)
    get options_review_path
    assert_response :success
    total = css_select("[data-testid=options-desk-summary-total-pnl]").first
    refute_match(/\$[\d,]+(?:\.\d{2})?/, total.text)

    negative, = broker_account(name: "NegMarkDesk", positions: [ position(symbol: "INTC  261113P00200000", strike: "200", price: "-1", basis: "1") ])
    get options_review_path
    assert_response :success
    negative_row = row_for(account_id: negative.id)
    refute_match(/\$0\.00/, negative_row)
    assert_match(/—|&mdash;|&#8212;|Unavailable/i, negative_row)
  end

  test "put screening is unavailable without candidates and covered calls stay account qualified excluding mini quotes" do
    shares, shares_provider = broker_account(name: "SharesDesk", positions: [])
    holding(account: shares, provider: shares_provider, ticker: "NVDA", qty: 300)
    empty, = broker_account(name: "NoSharesDesk", positions: [])
    covered_call_quotes
    mini = quote(type: "CALL", strike: 260, contract_size: "MINI", bid: "1.80", ask: "2.00", open_interest: 500)
    quote(type: "PUT", strike: 215, bid: "4.00", ask: "4.20", open_interest: 500)

    sign_in @owner
    get options_review_path
    assert_response :success

    puts_section = css_select("[data-testid=options-desk-puts-unavailable]").first
    assert puts_section, "missing options-desk-puts-unavailable"
    assert_match(/Put screening unavailable/i, puts_section.text)
    assert_match(/collateral not verified/i, puts_section.text)
    refute_match(/candidate/i, puts_section.text)

    ideas = css_select("[data-testid=options-desk-covered-call-idea]")
    assert ideas.any?, "expected covered-call candidates"
    ideas.each do |idea|
      assert_equal shares.id, idea["data-account-id"]
      refute_equal empty.id, idea["data-account-id"]
      refute_match(/#{Regexp.escape(mini.contract_symbol)}/, idea.to_s)
    end
    covered = css_select("[data-testid=options-desk-covered-calls]").first
    assert covered, "missing options-desk-covered-calls"
    assert_match(/Covered-call candidates/, covered.text)
    refute_match(/#{Regexp.escape(mini.contract_symbol)}/, covered.to_s)
    refute_match(/#{Regexp.escape(empty.id)}/, ideas.map(&:to_s).join)
  end

  test "ledger is a labelled scrollable table and every row carries account and contract hooks" do
    account, = broker_account(positions: [ position ])
    sign_in @owner
    get options_review_path
    assert_response :success

    assert_select "[tabindex='0'][aria-label] table[data-testid=options-desk-ledger]"
    assert_select "[data-testid=options-desk-ledger] caption"
    assert_select "[data-testid=options-desk-ledger] th[scope=col]", minimum: 1

    rows = css_select("[data-testid=options-desk-row]")
    assert_operator rows.size, :>=, 1
    rows.each do |row|
      assert row["data-account-id"].present?, "options-desk-row missing data-account-id"
      assert row["data-contract"].present?, "options-desk-row missing data-contract"
    end
    assert rows.any? { |row| row["data-account-id"] == account.id }
    assert rows.any? { |row| row["data-contract"].to_s.include?("NVDA") }
  end

  test "legacy route still renders for the owner with banner and a link back to the desk" do
    private_owner_book
    sign_in @owner
    get LEGACY_PATH
    assert_response :success
    assert_match "Legacy options review", response.body
    assert_select "a[href=?]", options_review_path
    assert_match "OwnerPrivateBrokerageZXQ", response.body
    assert_match "NVDA  261113P00215000", response.body
  end

  test "desk links to the preserved legacy path" do
    broker_account(positions: [ position ])
    sign_in @owner
    get options_review_path
    assert_response :success
    assert_select "[data-testid=options-desk] a[href=?]", LEGACY_PATH
  end

  test "unauthenticated desk access redirects to sign in even with hostile params" do
    get options_review_path
    assert_redirected_to new_session_path
    get options_review_path, params: { account: "1 OR 1=1" }
    assert_redirected_to new_session_path
  end

  test "unauthenticated legacy access redirects to sign in even with hostile params" do
    get LEGACY_PATH
    assert_redirected_to new_session_path
    get LEGACY_PATH, params: { account: [ "x" ] }
    assert_redirected_to new_session_path
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

    def holding(account:, provider:, ticker:, qty:, date: NOW.to_date)
      security = Security.find_or_create_by!(ticker: ticker) { |record| record.name = ticker }
      Holding.create!(account: account, account_provider: provider.account_provider, security: security, date: date,
                      qty: qty, price: 1, amount: qty, currency: account.currency)
    end

    def covered_call_quotes
      [
        [ 235, "2.70", "2.90" ],
        [ 240, "1.80", "2.00" ]
      ].each do |strike, bid, ask|
        quote(type: "CALL", strike: strike, bid: bid, ask: ask, open_interest: 500)
      end
    end

    def private_owner_book(name: "OwnerPrivateBrokerageZXQ", qty: "8881")
      account, = broker_account(name: name, positions: [ position(qty: qty, price: "5", basis: "1") ])
      [ account, "NVDA  261113P00215000" ]
    end

    def hostile_account_params(hidden_id:)
      [
        { account: hidden_id },
        { account: @other_user.family.accounts.first&.id || SecureRandom.uuid },
        { account: "garbage" },
        { account: [ "x" ] },
        { account: "1; DROP TABLE accounts;--" }
      ]
    end

    def desk_markup
      node = css_select("[data-testid=options-desk]").first
      node ? node.to_s : ""
    end

    def row_for(account_id:)
      row = css_select("[data-testid=options-desk-row][data-account-id='#{account_id}']").first
      assert row, "missing options-desk-row for #{account_id}"
      row.to_s
    end

    def assert_no_owner_leak(body, account:, contract:)
      refute_match(/#{Regexp.escape(contract)}/, body)
      refute_match(/#{Regexp.escape(account.name)}/, body)
      refute_match(/\b8881\b/, body)
      refute_match(/data-contract=["']#{Regexp.escape(contract)}["']/, body)
      refute_match(/data-account-id=["']#{account.id}["']/, body)
      refute_match(/\$3,552,400\.00|\$3552400\.00/, body)
    end
end
