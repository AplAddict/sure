require "application_system_test_case"

# Real-browser contract for options on the ticker page (/research/tickers/:ticker) and the holding drawer
# (/holdings/:id). Synthetic, test-only data; no provider or network. Screenshots go to tmp/screenshots/options-underlying/.
class OptionsUnderlyingSystemTest < ApplicationSystemTestCase
  DESKTOP = [ 1400, 1000 ].freeze
  PHONE = [ 390, 844 ].freeze
  SHOTS = Rails.root.join("tmp/screenshots/options-underlying")

  setup do
    FileUtils.mkdir_p(SHOTS)
    @user = users(:family_admin)
    @expiration = Date.current + 25
    @session = Options::MarketCalendar.latest_session(Time.current)
    sign_in @user
    build_book!
  end

  teardown { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  test "ticker page shows the NVDA options section with rows, subtotal, ideas and a link to the desk" do
    set_viewport(*DESKTOP)
    visit research_ticker_path("NVDA")

    assert_selector "[data-testid='ticker-options']", visible: true
    within("[data-testid='ticker-options']") do
      assert_equal 3, all("[data-testid='ticker-options-row']").size
      assert_text "QA Second Brokerage"
      assert_selector "[data-testid='ticker-options-subtotal']"
      assert_text "Day P&L unavailable - position change unknown"
      assert_selector "[data-testid='ticker-options-puts-unavailable']", text: "Put screening unavailable - collateral not verified"
      assert_selector "[data-testid='ticker-options-ideas']", text: "Research only"
      assert_link "Open full Options Desk"
      assert_no_selector "form"
      assert_no_selector "button"
    end
    assert_viewport_honoured
    scroll_to_testid("ticker-options")
    save_screenshot SHOTS.join("ticker-desktop.png")
    assert_no_document_overflow("desktop ticker page")

    set_viewport(*PHONE, mobile: true)
    visit research_ticker_path("NVDA")
    assert_viewport_honoured
    scroll_to_testid("ticker-options")
    save_screenshot SHOTS.join("ticker-mobile.png")
    wrapper = page.evaluate_script("(() => { const el = document.querySelector(\"[data-testid='ticker-options-ledger']\").closest('.overflow-x-auto'); return { scroll: el.scrollWidth, client: el.clientWidth }; })()")
    assert_operator wrapper.fetch("scroll"), :>, wrapper.fetch("client"), "the ticker ledger must scroll on its own on a phone"
    assert_no_document_overflow("mobile ticker page")
    page.execute_script("document.querySelector(\"[data-testid='ticker-options-ledger']\").closest('.overflow-x-auto').scrollLeft = 400")
    save_screenshot SHOTS.join("ticker-mobile-scrolled.png")
  end

  test "an option-only ticker (no shares) still shows its options on the ticker page" do
    set_viewport(*DESKTOP)
    visit research_ticker_path("TSLA")

    assert_selector "[data-testid='ticker-options']", visible: true
    assert_equal 1, all("[data-testid='ticker-options-row']").size
    scroll_to_testid("ticker-options")
    save_screenshot SHOTS.join("ticker-option-only-desktop.png")
  end

  test "a ticker with no options and no shares shows no options section" do
    set_viewport(*DESKTOP)
    visit research_ticker_path("IBM")

    assert_text "IBM"
    assert_no_selector "[data-testid='ticker-options']"
  end

  test "holding drawer shows only its own account's options, opened by default" do
    set_viewport(*DESKTOP)
    visit holding_path(@nvda_holding)

    assert_selector "[data-testid='holding-options']", visible: true
    within("[data-testid='holding-options']") do
      assert_equal 2, all("[data-testid='holding-options-row']").size
      assert_no_text "QA Second Brokerage"
      assert_selector "[data-testid='holding-options-subtotal']"
      assert_link "Open full Options Desk"
    end
    scroll_to_testid("holding-options")
    save_screenshot SHOTS.join("drawer-desktop.png")

    set_viewport(*PHONE, mobile: true)
    visit holding_path(@nvda_holding)
    assert_selector "[data-testid='holding-options']", visible: true
    scroll_to_testid("holding-options")
    save_screenshot SHOTS.join("drawer-mobile.png")
    assert_no_document_overflow("mobile holding drawer")
  end

  test "unreadable broker source shows unavailable wording on the ticker page, never no open contracts" do
    broker_account!(name: "QA Unreadable Brokerage", payload: "not-an-array")
    set_viewport(*DESKTOP)
    visit research_ticker_path("NVDA")

    assert_selector "[data-testid='ticker-options-source-banner']", text: /unavailable/i
    assert_no_text "No open option contracts"
    scroll_to_testid("ticker-options")
    save_screenshot SHOTS.join("ticker-unreadable-desktop.png")
  end

  private

    def set_viewport(width, height, mobile: false)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: mobile)
      @viewport = [ width, height ]
    end

    def scroll_to_testid(testid)
      page.execute_script("document.querySelector(\"[data-testid='#{testid}']\").scrollIntoView({ block: 'start' })")
    end

    def assert_viewport_honoured
      inner = page.evaluate_script("({ w: window.innerWidth, h: window.innerHeight })")
      assert_equal @viewport, [ inner.fetch("w"), inner.fetch("h") ], "browser did not apply the requested viewport"
    end

    def assert_no_document_overflow(label)
      widths = page.evaluate_script("({ scroll: document.documentElement.scrollWidth, client: document.documentElement.clientWidth })")
      assert_operator widths.fetch("scroll"), :<=, widths.fetch("client") + 1, "#{label} must not scroll horizontally (#{widths.inspect})"
    end

    def occ(root, type, strike)
      "#{root.ljust(6)}#{@expiration.strftime('%y%m%d')}#{type[0]}#{format('%08d', strike * 1000)}"
    end

    def position(root:, type:, strike:, qty:, price:, basis:)
      { "instrument" => { "symbol" => occ(root, type, strike), "option_type" => type, "expiration_date" => @expiration.to_s,
                          "strike_price" => strike.to_s, "multiplier" => "100" },
        "units" => qty.to_s, "price" => price.to_s, "cost_basis" => basis&.to_s, "currency" => { "code" => "USD" } }
    end

    def broker_account!(name:, payload:)
      suffix = SecureRandom.hex(4)
      account = @user.family.accounts.create!(name: name, balance: 1000, cash_balance: 0, currency: "USD", owner: @user,
                                              status: "active", accountable: Investment.new(subtype: "brokerage"))
      item = SnaptradeItem.create!(family: @user.family, name: "QA item #{suffix}", client_id: "qa-#{suffix}", consumer_key: "key-#{suffix}", status: "good")
      provider = SnaptradeAccount.create!(snaptrade_item: item, snaptrade_account_id: "qa-#{suffix}", name: name, currency: "USD",
                                          current_balance: 1000, last_holdings_sync: Time.current, raw_options_payload: payload)
      AccountProvider.create!(account: account, provider: provider)
      [ account, provider ]
    end

    def build_book!
      first, first_provider = broker_account!(name: "QA Options Brokerage", payload: [
        position(root: "NVDA", type: "PUT", strike: 215, qty: 2, price: 2.1, basis: 1.5),
        position(root: "NVDA", type: "CALL", strike: 250, qty: -1, price: 0.9, basis: 1.1),
        position(root: "TSLA", type: "PUT", strike: 180, qty: 1, price: 4.2, basis: 3.0)
      ])
      second, second_provider = broker_account!(name: "QA Second Brokerage", payload: [
        position(root: "NVDA", type: "CALL", strike: 260, qty: 1, price: 0.5, basis: 0.4)
      ])
      nvda = Security.find_or_create_by!(ticker: "NVDA") { |record| record.name = "NVIDIA" }
      Security.find_or_create_by!(ticker: "TSLA") { |record| record.name = "Tesla" }
      Security.find_or_create_by!(ticker: "IBM") { |record| record.name = "IBM" }
      @nvda_holding = Holding.create!(account: first, account_provider: first_provider.account_provider, security: nvda, date: Date.current,
                                      qty: 300, price: 217, amount: 300 * 217, currency: "USD")
      Holding.create!(account: second, account_provider: second_provider.account_provider, security: nvda, date: Date.current,
                      qty: 100, price: 217, amount: 100 * 217, currency: "USD")
      create_quote!("NVDA", "PUT", 215, bid: "2.00", ask: "2.20", last: "2.10")
      create_quote!("NVDA", "CALL", 235, bid: "1.90", ask: "2.00", last: "1.95")
    end

    def create_quote!(root, type, strike, bid:, ask:, last:)
      OptionQuote.create!(
        contract_symbol: "#{root}#{@expiration.strftime('%y%m%d')}#{type[0]}#{format('%08d', strike * 1000)}",
        underlying: root, option_type: type, strike: strike, expiration: @expiration,
        bid: bid, ask: ask, last_price: last, last_trade_at: Time.current - 5.minutes, quote_time: Time.current - 5.minutes,
        session_date: @session, underlying_price: "217.23", underlying_prev_close: "216", open_interest: 500,
        contract_size: "REGULAR", fetched_at: Time.current - 1.minute, source: "test", currency: "USD"
      )
    end
end
