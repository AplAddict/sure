require "test_helper"

class InvestmentIncomeReviewTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @period = Period.custom(start_date: Date.current.beginning_of_month, end_date: Date.current.end_of_month)
    @account = @family.accounts.create!(name: "Income #{SecureRandom.hex(3)}", balance: 1000, cash_balance: 0, currency: "USD", owner: @user, accountable: Investment.new)
  end

  test "separates dividends, interest, contributions and withdrawals by explicit label" do
    add_entry("Dividend", -30)
    add_entry("Interest", -5)
    add_entry("Contribution", -100)
    add_entry("Withdrawal", 40)
    add_entry("Fee", 3)

    review = InvestmentIncomeReview.new(user: @user, period: @period)

    assert_equal BigDecimal("30"), review.total(:dividends)
    assert_equal BigDecimal("5"), review.total(:interest)
    assert_equal BigDecimal("100"), review.total(:contributions)
    assert_equal BigDecimal("40"), review.total(:withdrawals)
    assert_equal BigDecimal("35"), review.income_total
    assert_equal BigDecimal("60"), review.net_contributions
  end

  test "a measured zero is distinct from unavailable foreign-currency evidence" do
    assert_equal BigDecimal("0"), InvestmentIncomeReview.new(user: @user, period: @period).total(:dividends)

    add_entry("Dividend", -10, currency: "EUR")
    review = InvestmentIncomeReview.new(user: @user, period: @period)

    assert_nil review.total(:dividends)
    assert_equal 1, review.missing_fx_count
    assert_nil review.income_total
  end

  test "converts foreign-currency entries when an exchange rate exists on the entry date" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: @period.start_date, rate: 1.5)
    add_entry("Dividend", -10, currency: "EUR", date: @period.start_date)

    assert_equal BigDecimal("15"), InvestmentIncomeReview.new(user: @user, period: @period).total(:dividends)
  end

  test "only includes accounts the user can access" do
    other_user = users(:empty)
    add_entry("Dividend", -30)

    assert_equal BigDecimal("0"), InvestmentIncomeReview.new(user: other_user, period: @period).total(:dividends)
  end

  test "option premium is never reported without a verified source label" do
    assert_not InvestmentIncomeReview.new(user: @user, period: @period).option_premium_available?
  end

  private
    def add_entry(label, amount, currency: "USD", date: @period.start_date)
      @account.entries.create!(name: label, amount: amount, date: date, currency: currency,
        entryable: Transaction.new(investment_activity_label: label))
    end
end
