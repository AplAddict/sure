require "test_helper"

class HoldingDayChangeTest < ActiveSupport::TestCase
  setup do
    @account = families(:empty).accounts.create!(name: "Day", balance: 100, cash_balance: 0, currency: "USD", accountable: Investment.new)
    @security = Security.create!(ticker: "DAYCH", name: "Day change")
  end

  test "same quantity reports the price-driven change" do
    Holding.create!(account: @account, security: @security, date: 1.day.ago.to_date, qty: 2, price: 100, amount: 200, currency: "USD")
    today = Holding.create!(account: @account, security: @security, date: Date.current, qty: 2, price: 110, amount: 220, currency: "USD")

    assert_equal 20, today.day_change.value.amount
  end

  test "a quantity change is unavailable instead of counting the purchase as market gain" do
    Holding.create!(account: @account, security: @security, date: 1.day.ago.to_date, qty: 2, price: 100, amount: 200, currency: "USD")
    today = Holding.create!(account: @account, security: @security, date: Date.current, qty: 5, price: 100, amount: 500, currency: "USD")

    assert_nil today.day_change
  end
end
