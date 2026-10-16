require "application_system_test_case"

# Real-browser contract for the Options Desk. All data is synthetic and test-only:
# broker payloads are written straight onto SnaptradeAccount rows and quotes are
# OptionQuote rows, so no provider or network is involved. Freshness is derived
# from the real clock via Options::MarketCalendar so the test is date-independent.
class OptionsDeskSystemTest < ApplicationSystemTestCase
  DESKTOP = [ 1400, 1000 ].freeze
  PHONE = [ 390, 844 ].freeze
  SHOTS = Rails.root.join("tmp/screenshots/options-desk")

  setup do
    FileUtils.mkdir_p(SHOTS)
    @user = users(:family_admin)
    @expiration = Date.current + 25
    @session = Options::MarketCalendar.latest_session(Time.current)
    sign_in @user
  end

  test "desktop desk shows the research alert, a ledger row per contract and honest unavailable cells" do
    build_readable_account!
    set_viewport(*DESKTOP)
    visit options_review_path

    within_testid("options-desk") do
      within_testid("options-desk-alert") { assert_text "Read-only research view" }
      assert_selector "[data-testid='options-desk-ledger']"
      assert_equal 3, all("[data-testid='options-desk-row']").size
      @contracts.each_value { |symbol| assert_selector "[data-testid='options-desk-row'][data-contract='#{symbol}']" }

      missing = find("[data-testid='options-desk-row'][data-contract='#{@contracts.fetch(:missing_basis)}']")
      assert_text_in_row missing, "—"
      assert_text_in_row missing, "Missing cost basis"

      assert_text "Unavailable - position change unknown"
      assert_selector "[data-testid='options-desk-puts-unavailable']", text: "Put screening unavailable"
      assert_selector "[data-testid='options-desk-covered-calls']", text: "Covered-call candidates"
    end

    assert_viewport_honoured
    save_screenshot SHOTS.join("desk-desktop.png")
    scroll_to_testid("options-desk-ledger")
    save_screenshot SHOTS.join("desk-desktop-ledger.png")
    scroll_to_testid("options-desk-covered-calls")
    save_screenshot SHOTS.join("desk-desktop-ideas.png")
    assert_no_document_overflow("desktop desk")
  end

  test "mobile desk keeps the page inside the viewport while the ledger scrolls on its own" do
    build_readable_account!
    set_viewport(*PHONE, mobile: true)
    visit options_review_path

    assert_viewport_honoured
    assert_selector "[data-testid='options-desk-alert']", visible: true
    assert_selector "[data-testid='options-desk-summary']", visible: true
    assert_no_document_overflow("mobile desk")

    wrapper = page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector("[data-testid='options-desk-ledger']").closest(".overflow-x-auto");
        return { scroll: el.scrollWidth, client: el.clientWidth };
      })()
    JS
    assert_operator wrapper.fetch("scroll"), :>, wrapper.fetch("client"), "the ledger wrapper must scroll horizontally on a phone"

    offenders = page.evaluate_script(<<~JS)
      (() => {
        const limit = document.documentElement.clientWidth + 1;
        return Array.from(document.querySelectorAll("body *"))
          .filter((el) => !el.closest(".overflow-x-auto") && !el.closest("[class*='sr-only']"))
          .filter((el) => el.getBoundingClientRect().width > 0 && el.getBoundingClientRect().right > limit)
          .filter((el) => getComputedStyle(el).position !== "fixed" && getComputedStyle(el).visibility !== "hidden")
          .slice(0, 10)
          .map((el) => el.tagName.toLowerCase() + "." + String(el.className).slice(0, 60) + " right=" + Math.round(el.getBoundingClientRect().right));
      })()
    JS
    assert_empty offenders, "elements overflow the #{PHONE.first}px viewport outside the ledger wrapper: #{offenders.inspect}"

    save_screenshot SHOTS.join("desk-mobile.png")

    page.execute_script("document.querySelector(\"[data-testid='options-desk-ledger']\").scrollIntoView({ block: 'start' })")
    save_screenshot SHOTS.join("desk-mobile-ledger.png")
    page.execute_script(<<~JS)
      document.querySelector("[data-testid='options-desk-ledger']").closest(".overflow-x-auto").scrollLeft = 400;
    JS
    save_screenshot SHOTS.join("desk-mobile-ledger-scrolled.png")
    assert_no_document_overflow("mobile desk after ledger scroll")
  end

  test "unreadable broker source withholds totals and says so" do
    build_readable_account!
    build_unreadable_account!
    set_viewport(*DESKTOP)
    visit options_review_path

    assert_selector "[data-testid='options-desk-source-banner']", visible: true
    assert_selector "[data-testid='options-desk-summary-unreadable']", text: "totals withheld"
    assert_selector "[data-testid='options-desk-summary-total-pnl']", text: "Total P&L"

    save_screenshot SHOTS.join("desk-unreadable-desktop.png")
    scroll_to_testid("options-desk-summary-unreadable")
    save_screenshot SHOTS.join("desk-unreadable-desktop-withheld.png")

    set_viewport(*PHONE, mobile: true)
    visit options_review_path
    assert_selector "[data-testid='options-desk-source-banner']", visible: true
    save_screenshot SHOTS.join("desk-unreadable-mobile.png")
    scroll_to_testid("options-desk-summary-unreadable")
    save_screenshot SHOTS.join("desk-unreadable-mobile-withheld.png")
    assert_no_document_overflow("mobile unreadable desk")
  end

  test "legacy route is labelled and links back to the desk" do
    build_readable_account!
    set_viewport(*DESKTOP)
    visit options_review_path

    within_testid("options-desk") { click_link "Open legacy view" }
    assert_selector "[data-testid='options-legacy-banner']", text: "Legacy options review"
    assert_no_selector "[data-testid='options-desk']"
    save_screenshot SHOTS.join("legacy-desktop.png")

    within_testid("options-legacy-banner") { click_link "Back to Options Desk" }
    assert_selector "[data-testid='options-desk']"
    assert_no_selector "[data-testid='options-legacy-banner']"

    set_viewport(*PHONE, mobile: true)
    visit legacy_options_review_path
    assert_selector "[data-testid='options-legacy-banner']"
    save_screenshot SHOTS.join("legacy-mobile.png")
  end

  teardown { page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") }

  private

    # resize_to sizes the OUTER window, and Chrome enforces a ~500px minimum window
    # width, so a 390px phone check would silently run at 500px. Override the
    # layout viewport through CDP instead and assert the browser honoured it.
    def set_viewport(width, height, mobile: false)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
                                      width: width, height: height, deviceScaleFactor: 1, mobile: mobile)
      visit "about:blank" if page.current_url.blank?
      @viewport = [ width, height ]
    end

    def scroll_to_testid(testid)
      page.execute_script("document.querySelector(\"[data-testid='#{testid}']\").scrollIntoView({ block: 'center' })")
    end

    def assert_viewport_honoured
      inner = page.evaluate_script("({ w: window.innerWidth, h: window.innerHeight })")
      assert_equal @viewport, [ inner.fetch("w"), inner.fetch("h") ], "browser did not apply the requested viewport"
    end

    def within_testid(testid, &block)
      within("[data-testid='#{testid}']", &block)
    end

    def assert_text_in_row(row, text)
      assert row.text.include?(text), "expected row #{row['data-contract']} to include #{text.inspect}, got #{row.text.inspect}"
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

    def build_readable_account!
      account, provider = broker_account!(name: "QA Options Brokerage", payload: [
        position(root: "NVDA", type: "PUT", strike: 215, qty: 2, price: 2.1, basis: 1.5),
        position(root: "NVDA", type: "CALL", strike: 250, qty: -1, price: 0.9, basis: 1.1),
        position(root: "AAPL", type: "CALL", strike: 260, qty: 1, price: 3.4, basis: nil)
      ])
      @contracts = { long_put: occ("NVDA", "PUT", 215), short_call: occ("NVDA", "CALL", 250), missing_basis: occ("AAPL", "CALL", 260) }

      security = Security.find_or_create_by!(ticker: "NVDA") { |record| record.name = "NVIDIA" }
      Holding.create!(account: account, account_provider: provider.account_provider, security: security, date: Date.current,
                      qty: 300, price: 217, amount: 300 * 217, currency: "USD")

      create_quote!("NVDA", "PUT", 215, bid: "2.00", ask: "2.20", last: "2.10")
      create_quote!("NVDA", "CALL", 235, bid: "1.90", ask: "2.00", last: "1.95")
    end

    def build_unreadable_account!
      broker_account!(name: "QA Unreadable Brokerage", payload: "not-an-array")
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
