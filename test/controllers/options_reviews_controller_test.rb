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
end
