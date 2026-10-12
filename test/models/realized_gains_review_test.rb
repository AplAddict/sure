require "test_helper"

class RealizedGainsReviewTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @period = Period.custom(start_date: Date.current.beginning_of_year, end_date: Date.current)
    @account = @family.accounts.create!(name: "Realized #{SecureRandom.hex(3)}", balance: 1000, cash_balance: 0, currency: "USD", owner: @user, accountable: Investment.new)
    @security = Security.create!(ticker: "RLZ#{SecureRandom.hex(2).upcase}", name: "Realized")
  end

  test "sums sale proceeds against the position's average cost, gains and losses separately" do
    holding(avg_cost: 10, date: 20.days.ago.to_date)
    sell(qty: -5, price: 14, date: 10.days.ago.to_date)   # +20
    sell(qty: -2, price: 7, date: 9.days.ago.to_date)     # -6

    review = RealizedGainsReview.new(user: @user, period: @period)

    assert_equal BigDecimal("20"), review.gains
    assert_equal BigDecimal("6"), review.losses
    assert_equal BigDecimal("14"), review.net
    assert_equal 2, review.measured_count
    assert_equal 0, review.excluded_count
  end

  test "a transfer to another owned account is not a realized gain" do
    holding(avg_cost: 10, date: 20.days.ago.to_date)
    sell(qty: -5, price: 50, date: 10.days.ago.to_date, label: "Transfer")

    review = RealizedGainsReview.new(user: @user, period: @period)

    assert_equal 0, review.measured_count
    assert_equal BigDecimal("0"), review.net
  end

  test "a sale with no cost basis is excluded and counted, never a zero gain" do
    sell(qty: -5, price: 14, date: 10.days.ago.to_date)

    review = RealizedGainsReview.new(user: @user, period: @period)

    assert_equal 0, review.measured_count
    assert_equal 1, review.excluded_count
    assert_equal({ no_cost_basis: 1 }, review.excluded_reasons)
    assert review.partial?
  end

  test "a foreign-currency basis without a rate on the sale date is excluded, not converted 1:1" do
    holding(avg_cost: 10, date: 20.days.ago.to_date, currency: "EUR")
    sell(qty: -5, price: 14, date: 10.days.ago.to_date, currency: "EUR")

    review = RealizedGainsReview.new(user: @user, period: @period)

    assert_equal 1, review.excluded_count
    assert_equal({ no_exchange_rate: 1 }, review.excluded_reasons)

    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: 10.days.ago.to_date, rate: 2)
    converted = RealizedGainsReview.new(user: @user, period: @period)
    assert_equal BigDecimal("40"), converted.net
  end

  test "groups by calendar month of the sale" do
    holding(avg_cost: 10, date: 100.days.ago.to_date)
    sell(qty: -1, price: 12, date: 70.days.ago.to_date)
    sell(qty: -1, price: 15, date: 5.days.ago.to_date)

    months = RealizedGainsReview.new(user: @user, period: Period.custom(start_date: 90.days.ago.to_date, end_date: Date.current)).monthly

    assert_equal [ 2, 5 ], months.sort_by(&:month).map(&:net).map(&:to_i)
  end

  test "only counts sales in accounts the user can access and inside the period" do
    holding(avg_cost: 10, date: 400.days.ago.to_date)
    sell(qty: -1, price: 20, date: 5.days.ago.to_date)
    sell(qty: -1, price: 20, date: 300.days.ago.to_date)

    assert_equal BigDecimal("0"), RealizedGainsReview.new(user: users(:empty), period: @period).net
    assert_equal 1, RealizedGainsReview.new(user: @user, period: @period).measured_count
  end

  private
    def holding(avg_cost:, date:, currency: "USD")
      Holding.create!(account: @account, security: @security, date: date, qty: 10, price: avg_cost, amount: 10 * avg_cost, currency: currency, cost_basis: avg_cost, cost_basis_source: "manual", cost_basis_locked: true)
    end

    def sell(qty:, price:, date:, label: nil, currency: "USD")
      @account.entries.create!(name: "Sell", amount: qty.abs * price, date: date, currency: currency,
        entryable: Trade.new(security: @security, qty: qty, price: price, currency: currency, investment_activity_label: label))
    end
end
