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

  test "a reversal reduces income instead of being turned positive" do
    add_entry("Dividend", -30)
    add_entry("Dividend", 12)   # broker reversal: opposite sign

    assert_equal BigDecimal("18"), InvestmentIncomeReview.new(user: @user, period: @period).total(:dividends)
  end

  test "option premium keeps the broker's cash sign, so fees exceeding proceeds reduce the total" do
    snaptrade_for(@account, [
      option_activity("SELL_TO_OPEN", 100.00, date: @period.start_date),
      option_activity("SELL_TO_OPEN", -0.66, date: @period.start_date)   # fees exceeded proceeds
    ])

    premium = InvestmentIncomeReview.new(user: @user, period: @period).option_premium

    assert_equal BigDecimal("99.34"), premium[:sold_to_open]
    assert_equal BigDecimal("99.34"), premium[:net]
  end

  test "one unconvertible option trade makes only its own category unavailable, not a partial sum" do
    snaptrade_for(@account, [
      option_activity("SELL_TO_OPEN", 100.00, date: @period.start_date),
      option_activity("SELL_TO_OPEN", 10.00, date: @period.start_date, currency: "EUR"),
      option_activity("BUY_TO_CLOSE", -20.00, date: @period.start_date)
    ])

    premium = InvestmentIncomeReview.new(user: @user, period: @period).option_premium

    assert_nil premium[:sold_to_open]
    assert_equal BigDecimal("20.00"), premium[:bought_to_close]
    assert_nil premium[:net]
  end

  test "an option trade with no currency is unavailable rather than assumed to be the family currency" do
    snaptrade_for(@account, [ option_activity("SELL_TO_OPEN", 50.00, date: @period.start_date, currency: nil) ])

    premium = InvestmentIncomeReview.new(user: @user, period: @period).option_premium

    assert_nil premium[:sold_to_open]
    assert_nil premium[:net]
    assert_equal 1, premium[:unconverted]
  end

  test "period market return is unavailable without balance evidence in the period" do
    assert_nil InvestmentIncomeReview.new(user: @user, period: @period).period_return_trend
  end

  test "period market return is unavailable when an investment account is in another currency" do
    @family.accounts.create!(name: "Euro #{SecureRandom.hex(3)}", balance: 1000, cash_balance: 0, currency: "EUR", owner: @user, accountable: Investment.new)

    assert_nil InvestmentIncomeReview.new(user: @user, period: @period).period_return_trend
  end

  test "money-weighted return solves the account's balances and contributions" do
    period = Period.custom(start_date: 40.days.ago.to_date, end_date: 10.days.ago.to_date)
    balance_row(period.start_date - 1.day, 1000)
    balance_row(period.end_date, 1700)
    add_entry("Contribution", -500, date: period.start_date + 15.days)

    result = InvestmentIncomeReview.new(user: @user, period: period).money_weighted_return
    expected = Portfolio::Xirr.rate([
      [ period.start_date, -1000 ], [ period.start_date + 15.days, -500 ], [ period.end_date, 1700 ]
    ], days_per_unit: (period.end_date - period.start_date).to_i)

    assert_in_delta expected.to_f, result.rate.to_f, 0.000001
    assert_operator result.rate, :>, 0
    assert_equal false, result.ambiguous
  end

  test "money-weighted return is unavailable without a start balance, an end balance, or complete flows" do
    period = Period.custom(start_date: 40.days.ago.to_date, end_date: 10.days.ago.to_date)

    assert_nil InvestmentIncomeReview.new(user: @user, period: period).money_weighted_return, "no balance rows"

    balance_row(period.end_date, 1700)
    assert_nil InvestmentIncomeReview.new(user: @user, period: period).money_weighted_return, "no opening balance"

    balance_row(period.start_date - 1.day, 1000)
    assert InvestmentIncomeReview.new(user: @user, period: period).money_weighted_return

    add_entry("Contribution", -50, currency: "EUR", date: period.start_date + 3.days)
    assert_nil InvestmentIncomeReview.new(user: @user, period: period).money_weighted_return, "a flow needing a missing exchange rate"
  end

  test "money-weighted return is unavailable when money only went one way" do
    period = Period.custom(start_date: 40.days.ago.to_date, end_date: 10.days.ago.to_date)
    @account.update!(balance: 0)
    balance_row(period.start_date - 1.day, 0)
    balance_row(period.end_date, 0)
    add_entry("Contribution", -100, date: period.start_date + 3.days)

    assert_nil InvestmentIncomeReview.new(user: @user, period: period).money_weighted_return
  end

  test "risk metrics treat contributions and withdrawals as flows, not returns" do
    period = Period.custom(start_date: 30.days.ago.to_date, end_date: 5.days.ago.to_date)
    (period.start_date - 1.day).upto(period.end_date) do |date|
      value = if date < period.start_date + 5.days then 1000
      elsif date < period.start_date + 12.days then 1500
      else 1300
      end
      balance_row(date, value)
    end
    add_entry("Contribution", -500, date: period.start_date + 5.days)
    add_entry("Withdrawal", 200, date: period.start_date + 12.days)

    metrics = InvestmentIncomeReview.new(user: @user, period: period).risk_metrics

    assert_equal 26, metrics.data_points
    assert_in_delta 0, metrics.volatility.to_f, 0.000001
    assert_in_delta 0, metrics.max_drawdown.to_f, 0.000001
  end

  test "risk metrics measure annualised volatility and the deepest peak-to-trough fall" do
    period = Period.custom(start_date: 30.days.ago.to_date, end_date: 5.days.ago.to_date)
    (period.start_date - 1.day).upto(period.end_date) do |date|
      value = if date < period.start_date + 10.days then 1000
      elsif date == period.start_date + 10.days then 1100
      else 990
      end
      balance_row(date, value)
    end

    metrics = InvestmentIncomeReview.new(user: @user, period: period).risk_metrics

    returns = [ 0.1, -0.1 ] + [ 0.0 ] * 24
    mean = returns.sum / returns.size
    daily_stdev = Math.sqrt(returns.sum { |r| (r - mean)**2 } / (returns.size - 1))
    assert_equal 26, metrics.data_points
    assert_in_delta daily_stdev * Math.sqrt(365), metrics.volatility.to_f, 0.0001
    assert_in_delta 0.1, metrics.max_drawdown.to_f, 0.000001
  end

  test "risk metrics are unavailable with fewer than 20 daily points, a foreign flow, or no access" do
    period = Period.custom(start_date: 30.days.ago.to_date, end_date: 5.days.ago.to_date)
    (period.start_date - 1.day).upto(period.start_date + 15.days) { |date| balance_row(date, 1000) }
    assert_nil InvestmentIncomeReview.new(user: @user, period: period).risk_metrics, "too few points"

    (period.start_date + 16.days).upto(period.end_date) { |date| balance_row(date, 1000) }
    assert InvestmentIncomeReview.new(user: @user, period: period).risk_metrics
    assert_nil InvestmentIncomeReview.new(user: users(:empty), period: period).risk_metrics, "no access"

    add_entry("Contribution", -50, currency: "EUR", date: period.start_date + 3.days)
    assert_nil InvestmentIncomeReview.new(user: @user, period: period).risk_metrics, "foreign flow"
  end

  test "money-weighted return ignores accounts the user cannot access" do
    period = Period.custom(start_date: 40.days.ago.to_date, end_date: 10.days.ago.to_date)
    balance_row(period.start_date - 1.day, 1000)
    balance_row(period.end_date, 1500)

    assert_nil InvestmentIncomeReview.new(user: users(:empty), period: period).money_weighted_return
  end

  test "monthly income groups dividends and interest by the month they were paid" do
    month = Period.custom(start_date: 70.days.ago.to_date, end_date: Date.current)
    add_entry("Dividend", -10, date: 65.days.ago.to_date)
    add_entry("Interest", -2, date: 64.days.ago.to_date)
    add_entry("Dividend", -7, date: 3.days.ago.to_date)

    rows = InvestmentIncomeReview.new(user: @user, period: month).monthly_income

    assert_equal [ 12, 7 ], rows.sort_by(&:month).map { |row| row.total.to_i }
    assert_equal [ 10, 7 ], rows.sort_by(&:month).map { |row| row.dividends.to_i }
  end

  test "a month needing a missing exchange rate is unavailable rather than partial" do
    period = Period.custom(start_date: 40.days.ago.to_date, end_date: Date.current)
    add_entry("Dividend", -10, date: 3.days.ago.to_date)
    add_entry("Dividend", -9, currency: "EUR", date: 3.days.ago.to_date)

    row = InvestmentIncomeReview.new(user: @user, period: period).monthly_income.last
    assert_nil row.dividends
    assert_nil row.total
  end

  test "monthly totals add every month and stay unavailable if any month is" do
    period = Period.custom(start_date: 70.days.ago.to_date, end_date: Date.current)
    add_entry("Dividend", -10, date: 65.days.ago.to_date)
    add_entry("Interest", -2, date: 64.days.ago.to_date)
    add_entry("Dividend", -7, date: 3.days.ago.to_date)

    totals = InvestmentIncomeReview.new(user: @user, period: period).monthly_totals
    assert_equal 17, totals.dividends.to_i
    assert_equal 2, totals.interest.to_i
    assert_equal 19, totals.total.to_i

    add_entry("Dividend", -9, currency: "EUR", date: 3.days.ago.to_date)
    totals = InvestmentIncomeReview.new(user: @user, period: period).monthly_totals
    assert_nil totals.dividends
    assert_nil totals.total
    assert_equal 2, totals.interest.to_i
  end

  test "monthly totals of nothing are unavailable, not zero" do
    assert_nil InvestmentIncomeReview.new(user: @user, period: Period.custom(start_date: 5.days.ago.to_date, end_date: Date.current)).monthly_totals
  end

  private
    # Records the account's balance on a date, and zero for every other
    # investment account the user can see, so the review has complete evidence.
    def balance_row(date, value)
      @account.balances.create!(date: date, currency: "USD", balance: value, cash_balance: 0, start_non_cash_balance: value)
      InvestmentIncomeReview.new(user: @user, period: @period).accounts.where.not(id: @account.id).each do |other|
        next if other.balances.exists?(date: date, currency: other.currency)

        other.balances.create!(date: date, currency: other.currency, balance: 0, cash_balance: 0, start_non_cash_balance: 0)
      end
    end

    def option_activity(option_type, amount, date:, currency: "USD")
      { "type" => option_type.start_with?("SELL") ? "SELL" : "BUY", "option_type" => option_type, "amount" => amount,
        "trade_date" => "#{date}T04:00:00Z", "currency" => (currency ? { "code" => currency } : nil) }
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
