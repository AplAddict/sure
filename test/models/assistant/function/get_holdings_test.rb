require "test_helper"

class Assistant::Function::GetHoldingsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.create!(
      name: "Euro brokerage",
      owner: @user,
      balance: 100,
      currency: "EUR",
      accountable: Investment.new
    )
    @security = Security.create!(ticker: "EURTEST", name: "Euro holding")
    @account.holdings.create!(
      security: @security,
      date: Date.current,
      qty: 1,
      price: 100,
      amount: 100,
      currency: "EUR"
    )
    @fn = Assistant::Function::GetHoldings.new(@user)
  end

  test "converts the total to family currency" do
    ExchangeRate.where(from_currency: "EUR", to_currency: @family.currency, date: Date.current).delete_all
    ExchangeRate.create!(from_currency: "EUR", to_currency: @family.currency, date: Date.current, rate: 1.5)

    result = @fn.call("page" => 1, "accounts" => [ @account.name ])

    assert_equal Money.new(150, @family.currency).format, result[:total_value]
  end

  test "reports an unavailable total when exchange rate is missing" do
    ExchangeRate.where(from_currency: "EUR", to_currency: @family.currency, date: Date.current).delete_all

    result = @fn.call("page" => 1, "accounts" => [ @account.name ])

    assert_equal "Unavailable", result[:total_value]
  end

  test "excludes holdings from another member's unshared account" do
    member = users(:family_member)
    private_account = @family.accounts.create!(
      name: "Private member brokerage",
      owner: member,
      balance: 500,
      currency: @family.currency,
      accountable: Investment.new
    )
    private_security = Security.create!(ticker: "PRIVATEHOLD", name: "Private holding")
    private_holding = private_account.holdings.create!(
      security: private_security,
      date: Date.current,
      qty: 5,
      price: 100,
      amount: 500,
      currency: @family.currency
    )

    result = @fn.call("page" => 1)

    assert_not_includes result[:holdings].map { |holding| holding[:ticker] }, private_holding.ticker
  end
end
