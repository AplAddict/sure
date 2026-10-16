require "test_helper"

# Options on Portfolio > Holdings (GET /portfolio/holdings): each broker-linked account block carries that account's own
# open contracts from the approved OptionsDesk read model. Ticker links must also leave the account-tab Turbo frame.
class PortfolioHoldingsOptionsTest < ActionDispatch::IntegrationTest
  NOW = Time.utc(2026, 10, 15, 15, 0)
  EXPIRATION = Date.new(2026, 11, 13)
  BANNED = /cash-secured|safe|best|opportunity|top ideas|sell|buy now|trade now|execute|place order/i

  setup do
    travel_to NOW
    ensure_tailwind_build
    @owner = users(:family_admin)
    sign_in @owner
  end

  teardown { travel_back }

  def broker_account(owner: @owner, name: nil, freshness: Time.current, positions: [], raw_options_payload: positions, currency: "USD")
    suffix = SecureRandom.hex(4)
    account = owner.family.accounts.create!(name: name || "Brokerage #{suffix}", balance: 1000, cash_balance: 100, currency: currency, owner: owner,
                                            status: "active", accountable: Investment.new(subtype: "brokerage"))
    item = SnaptradeItem.create!(family: owner.family, name: "Item #{suffix}", client_id: "client-#{suffix}", consumer_key: "key-#{suffix}", status: "good")
    provider = SnaptradeAccount.create!(snaptrade_item: item, snaptrade_account_id: "ph-#{suffix}", name: account.name, currency: currency,
                                        current_balance: 1000, last_holdings_sync: freshness, raw_options_payload: raw_options_payload)
    AccountProvider.create!(account: account, provider: provider)
    [ account, provider ]
  end

  def manual_account(name: "Manual brokerage")
    @owner.family.accounts.create!(name: name, balance: 1000, cash_balance: 100, currency: "USD", owner: @owner,
                                   status: "active", accountable: Investment.new(subtype: "brokerage"))
  end

  def position(symbol: "NVDA  261113P00215000", type: "PUT", strike: "215", qty: "1", price: "2", basis: "1", multiplier: "100", currency: "USD")
    { "instrument" => { "symbol" => symbol, "option_type" => type, "expiration_date" => EXPIRATION.to_s, "strike_price" => strike, "multiplier" => multiplier },
      "units" => qty, "price" => price, "cost_basis" => basis, "currency" => { "code" => currency } }
  end

  def stock(account, ticker:, qty: 10)
    security = Security.find_or_create_by!(ticker: ticker) { |record| record.name = ticker }
    Holding.create!(account: account, security: security, date: NOW.to_date, qty: qty, price: 100, amount: qty * 100, currency: "USD")
  end

  def block_for(account)
    css_select("[data-testid=holdings-account]").find { |node| node["aria-labelledby"] == "ph-#{account.id}" }
  end

  def options_in(account)
    block = block_for(account)
    assert block, "the account block must render"
    block.css("[data-testid=holdings-account-options]").first
  end

  test "a broker-linked account block shows that account's own contracts" do
    account, = broker_account(positions: [ position ])
    stock(account, ticker: "NVDA")
    other, = broker_account(positions: [ position(symbol: "AAPL  261113C00230000", type: "CALL", strike: "230") ])
    stock(other, ticker: "AAPL")
    get portfolio_holdings_path

    assert_response :success
    mine = options_in(account)
    assert mine, "options render inside the account's own block"
    assert_includes mine.text.squish, "NVDA 261113P00215000"
    assert_not_includes mine.text, "AAPL"
    theirs = options_in(other)
    assert_includes theirs.text.squish, "AAPL 261113C00230000"
    assert_not_includes theirs.text, "NVDA"
    assert_no_match(BANNED, mine.text)
  end

  test "an account scope narrows the page to that account's contracts" do
    account, = broker_account(positions: [ position ])
    stock(account, ticker: "NVDA")
    other, = broker_account(positions: [ position(symbol: "AAPL  261113C00230000", type: "CALL", strike: "230") ])
    stock(other, ticker: "AAPL")
    get portfolio_holdings_path(account: account.id)

    assert_response :success
    assert_select "[data-testid=holdings-account-options]", count: 1
    assert_no_match(/AAPL 261113C00230000/, css_select("[data-testid=holdings-account-options]").first.text.squish)
  end

  test "a manual account has no options section and no broker notice" do
    manual = manual_account
    stock(manual, ticker: "MSFT")
    get portfolio_holdings_path

    assert_response :success
    assert block_for(manual)
    assert_nil options_in(manual)
    assert_no_match(/option data unavailable/i, response.body)
  end

  test "a readable broker account with no contracts shows no options section" do
    account, = broker_account(positions: [])
    stock(account, ticker: "NVDA")
    get portfolio_holdings_path

    assert_response :success
    assert_nil options_in(account)
  end

  test "an unreadable options payload says unavailable and never reads as no contracts" do
    account, = broker_account(positions: [], raw_options_payload: "not-an-array")
    stock(account, ticker: "NVDA")
    get portfolio_holdings_path

    assert_response :success
    section = options_in(account)
    assert section, "an unreadable source must surface a notice"
    assert_match(/unavailable/i, section.text)
    assert_no_match(/no open contracts/i, section.text)
  end

  test "a stale snapshot keeps the stale banner" do
    account, = broker_account(freshness: 5.days.ago, positions: [ position ])
    stock(account, ticker: "NVDA")
    get portfolio_holdings_path

    section = options_in(account)
    assert section
    assert_match(/stale|older|not current/i, section.text)
    assert_not_includes section.text, "$0.00"
  end

  test "the section is read-only and links to the full desk for that account" do
    account, = broker_account(positions: [ position ])
    stock(account, ticker: "NVDA")
    get portfolio_holdings_path

    section = options_in(account)
    assert_empty section.css("form, input, button[type=submit]")
    link = section.css("a").find { |anchor| anchor["href"].to_s.start_with?("/portfolio/options") && !anchor["href"].include?("legacy") }
    assert link, "a link to the full Options Desk"
    assert_includes link["href"], "account=#{account.id}"
  end

  test "another member never sees the owner's private account options" do
    account, = broker_account(positions: [ position ])
    stock(account, ticker: "NVDA")
    sign_in users(:family_member)
    get portfolio_holdings_path

    assert_not_includes response.body, "NVDA 261113P00215000"
  end

  test "a hostile account param fails closed" do
    account, = broker_account(positions: [ position ])
    stock(account, ticker: "NVDA")
    get portfolio_holdings_path(account: SecureRandom.uuid)

    assert_response :not_found
  end

  test "ticker links in the account tab leave the Turbo frame in both views" do
    account, = broker_account(positions: [])
    stock(account, ticker: "NVDA")

    %w[compact advanced].each do |view|
      get holdings_url(account_id: account.id, view: view)
      assert_response :success
      links = css_select("turbo-frame a[href='#{research_ticker_path("NVDA")}']")
      assert links.any?, "#{view} view links the ticker"
      links.each { |link| assert_equal "_top", link["data-turbo-frame"], "#{view} view ticker link must target _top: #{link.to_html}" }
    end
  end
end
