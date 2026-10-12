require "test_helper"

class OptionsReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:family_admin)
    @member = users(:family_member)
    @account = @owner.family.accounts.create!(
      name: "Owner Options Brokerage", balance: 1000, cash_balance: 0, currency: "USD", owner: @owner,
      status: "active", accountable: Investment.new(subtype: "brokerage")
    )
    item = SnaptradeItem.create!(family: @owner.family, name: "Options broker", client_id: "options-client", consumer_key: "options-key", status: "good")
    @provider_account = SnaptradeAccount.create!(
      snaptrade_item: item, snaptrade_account_id: "options-account", name: "Options broker", currency: "USD", current_balance: 1000,
      raw_options_payload: [ { "instrument" => { "symbol" => "AAPL  270115C00250000", "option_type" => "CALL", "expiration_date" => "2027-01-15", "strike_price" => "250", "multiplier" => "100" }, "units" => "1", "price" => "12.5", "cost_basis" => "10", "currency" => { "code" => "USD" } } ],
      last_holdings_sync: Time.current
    )
    AccountProvider.create!(account: @account, provider: @provider_account)
  end

  test "shows only the signed-in user's read-only option snapshot fields" do
    sign_in @owner
    get options_review_path

    assert_response :success
    assert_match "AAPL  270115C00250000", response.body
    assert_match "Owner Options Brokerage", response.body
    assert_match "Read-only", response.body
    assert_match "Gain / loss", response.body
    assert_match "$250.00", response.body
    assert_match "25.0%", response.body
    assert_no_match(/Greeks|Implied volatility|Trade now/i, response.body)
  end

  test "does not expose another family member's private option position" do
    sign_in @member
    get options_review_path

    assert_response :success
    assert_no_match(/AAPL  270115C00250000/, response.body)
    assert_no_match(/Owner Options Brokerage/, response.body)
  end

  def add_contract(symbol:, expiry:, units: "1", price: "2", cost: "1", type: "PUT")
    @provider_account.update!(raw_options_payload: @provider_account.raw_options_payload + [
      { "instrument" => { "symbol" => symbol, "option_type" => type, "expiration_date" => expiry, "strike_price" => "100", "multiplier" => "100" }, "units" => units, "price" => price, "cost_basis" => cost, "currency" => { "code" => "USD" } }
    ])
  end

  test "groups contracts by underlying with a subtotal that only counts measured gains" do
    add_contract(symbol: "AAPL  261218P00200000", expiry: "2026-12-18", price: "3", cost: "1")
    add_contract(symbol: "MSFT  261218C00400000", expiry: "2026-12-18", price: nil, cost: "5")
    sign_in @owner
    get options_review_path

    assert_response :success
    assert_select "[data-testid=options-group]", count: 2
    assert_select "[data-testid=options-group][data-underlying=AAPL] [data-testid=options-subtotal]", text: /\$/
    assert_select "[data-testid=options-group][data-underlying=MSFT] [data-testid=options-subtotal]", text: /—|Unavailable/
  end

  test "flags a contract expiring within a week and an expired one" do
    add_contract(symbol: "SOON  261014C00050000", expiry: (Date.current + 3.days).iso8601)
    add_contract(symbol: "GONE  261001C00050000", expiry: (Date.current - 2.days).iso8601)
    sign_in @owner
    get options_review_path

    assert_select "[data-testid=option-expiry-soon]", minimum: 1
    assert_select "[data-testid=option-expired]", minimum: 1
    assert_select "[data-testid=option-expiry-soon]", text: /3 days|Expires/i
  end

  test "can be sorted by expiry, gain or underlying and ignores unknown sorts" do
    sign_in @owner
    %w[expiry gain underlying contract].each do |sort|
      get options_review_path(sort: sort, dir: "desc")
      assert_response :success
    end
    get options_review_path(sort: "bogus; drop table")
    assert_response :success
    assert_select "th[aria-sort=ascending], th[aria-sort=descending]", count: 1
    assert_select "th[aria-sort=none] a", minimum: 4
    assert_select "th a[aria-sort]", count: 0
  end

  test "keeps the contract column pinned and wraps the table for narrow screens" do
    sign_in @owner
    get options_review_path
    assert_select "th.sticky, td.sticky", minimum: 1
  end

  test "summary totals only counted when every figure is known" do
    sign_in @owner
    get options_review_path
    assert_select "[data-testid=options-summary]"
  end

  test "options summary and contracts are draggable sections" do
    sign_in @owner
    get options_review_path

    assert_response :success
    assert_equal %w[summary contracts], css_select("[data-reports-sortable-target=section]").map { |n| n["data-section-key"] }
    assert_select "[data-section-key=summary] [data-testid=options-summary]"
    assert_select "[data-section-key=contracts] table"
  end

  test "an empty options page shows the empty state instead of sections" do
    sign_in users(:family_member)
    get options_review_path

    assert_response :success
    assert_empty css_select("[data-reports-sortable-target=section]").map { |n| n["data-section-key"] }
  end

end
