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

  test "option premium comes from broker open/close tags, separated and net of fees" do
    snap = snaptrade_for(@account, [
      option_activity("SELL_TO_OPEN", 57.34, date: @period.start_date),
      option_activity("SELL_TO_OPEN", 100.00, date: @period.start_date),
      option_activity("BUY_TO_CLOSE", -14.02, date: @period.start_date),
      option_activity("BUY_TO_OPEN", -67.66, date: @period.start_date),
      option_activity("SELL_TO_CLOSE", 7.58, date: @period.start_date),
      option_activity("SELL_TO_OPEN", 999.00, date: @period.start_date - 40.days),
      { "type" => "DIVIDEND", "amount" => 50, "trade_date" => "#{@period.start_date}T04:00:00Z", "currency" => { "code" => "USD" } }
    ])

    premium = InvestmentIncomeReview.new(user: @user, period: @period).option_premium

    assert_equal BigDecimal("157.34"), premium[:sold_to_open]
    assert_equal BigDecimal("67.66"), premium[:bought_to_open]
    assert_equal BigDecimal("14.02"), premium[:bought_to_close]
    assert_equal BigDecimal("7.58"), premium[:sold_to_close]
    assert_equal BigDecimal("83.24"), premium[:net]
    assert_equal 5, premium[:count]
    assert snap
  end

  test "option premium is a measured zero with no option activity, and unavailable for foreign currency" do
    assert_equal BigDecimal("0"), InvestmentIncomeReview.new(user: @user, period: @period).option_premium[:net]

    snaptrade_for(@account, [ option_activity("SELL_TO_OPEN", 10, date: @period.start_date, currency: "EUR") ])
    review = InvestmentIncomeReview.new(user: @user, period: @period)

    assert_nil review.option_premium[:net]
    assert_equal 1, review.option_premium[:unconverted]
  end

  test "option premium excludes accounts the user cannot access" do
    snaptrade_for(@account, [ option_activity("SELL_TO_OPEN", 50, date: @period.start_date) ])

    assert_equal BigDecimal("0"), InvestmentIncomeReview.new(user: users(:empty), period: @period).option_premium[:net]
  end

  private
    def option_activity(option_type, amount, date:, currency: "USD")
      { "type" => option_type.start_with?("SELL") ? "SELL" : "BUY", "option_type" => option_type, "amount" => amount,
        "trade_date" => "#{date}T04:00:00Z", "currency" => { "code" => currency } }
    end

    def snaptrade_for(account, activities)
      item = SnaptradeItem.create!(family: @family, name: "Premium #{SecureRandom.hex(3)}", client_id: "c#{SecureRandom.hex(2)}", consumer_key: "k", status: "good")
      provider = SnaptradeAccount.create!(snaptrade_item: item, snaptrade_account_id: "p#{SecureRandom.hex(4)}", name: "Premium", currency: "USD",
                                          current_balance: 1000, raw_activities_payload: activities)
      AccountProvider.create!(account: account, provider: provider)
      provider
    end

    def add_entry(label, amount, currency: "USD", date: @period.start_date)
      @account.entries.create!(name: label, amount: amount, date: date, currency: currency,
        entryable: Transaction.new(investment_activity_label: label))
    end
end
