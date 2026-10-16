require "application_system_test_case"

# Ticker links inside the account page's Holdings tab live in a Turbo frame. A link without a frame target tries to
# load the whole ticker page into that frame and fails with "Content missing". Real browser, test-only data.
class TickerLinksSystemTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    sign_in @user
    @account = @user.family.accounts.create!(name: "Link QA Brokerage", balance: 1000, cash_balance: 0, currency: "USD", owner: @user,
                                             status: "active", accountable: Investment.new(subtype: "brokerage"))
    security = Security.find_or_create_by!(ticker: "NVDA") { |record| record.name = "NVIDIA" }
    Holding.create!(account: @account, security: security, date: Date.current, qty: 10, price: 100, amount: 1000, currency: "USD")
  end

  test "ticker links in the account Holdings tab open the full ticker page, compact and advanced" do
    %w[compact advanced].each do |view|
      visit holdings_path(account_id: @account.id, view: view)
      within("turbo-frame##{ActionView::RecordIdentifier.dom_id(@account, :holdings)}") do
        first("a[href='#{research_ticker_path("NVDA")}']").click
      end
      assert_current_path research_ticker_path("NVDA")
      assert_selector "h1", text: "NVDA"
      assert_no_text "Content missing"
    end
  end

  test "ticker links on Portfolio Holdings open the ticker page and the account's options render" do
    visit portfolio_holdings_path
    within("[data-testid=holding-row]", match: :first) { click_link "NVDA" }
    assert_current_path research_ticker_path("NVDA")
    assert_selector "h1", text: "NVDA"
    assert_no_text "Content missing"
  end

  test "Portfolio Holdings shows each broker account's contracts inside its own block" do
    expiration = Date.current + 25
    item = SnaptradeItem.create!(family: @user.family, name: "QA item", client_id: "qa-client", consumer_key: "qa-key", status: "good")
    provider = SnaptradeAccount.create!(snaptrade_item: item, snaptrade_account_id: "qa-opt", name: @account.name, currency: "USD", current_balance: 1000,
                                        last_holdings_sync: Time.current, raw_options_payload: [
                                          { "instrument" => { "symbol" => "NVDA  #{expiration.strftime('%y%m%d')}P00215000", "option_type" => "PUT", "expiration_date" => expiration.to_s,
                                                              "strike_price" => "215", "multiplier" => "100" },
                                            "units" => "-1", "price" => "2.1", "cost_basis" => "3.0", "currency" => { "code" => "USD" } }
                                        ])
    AccountProvider.create!(account: @account, provider: provider)

    [ [ 1400, 1000, false ], [ 390, 844, true ] ].each do |width, height, mobile|
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: height, deviceScaleFactor: 1, mobile: mobile)
      visit portfolio_holdings_path
      assert_selector "[data-testid=holdings-account-options]", visible: true
      within("[data-testid=holdings-account-options]") do
        assert_text "Options contracts"
        assert_text "NVDA $215 Put"
        assert_link "Open full Options Desk"
        assert_no_selector "form"
      end
      page.execute_script("document.querySelector('[data-testid=holdings-account-options]').scrollIntoView({block: 'center'})")
      FileUtils.mkdir_p(Rails.root.join("tmp/screenshots/portfolio-options"))
      save_screenshot Rails.root.join("tmp/screenshots/portfolio-options/holdings-#{mobile ? 'mobile' : 'desktop'}.png")
    end
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
