# Read-only income and cash-flow review for the accounts a user can access.
#
# Every figure is summed from entries that carry an explicit provider/user
# activity label. Nothing is inferred from trade direction, and a total that
# depends on a missing exchange rate is nil (unavailable) rather than a partial
# sum or a fabricated zero.
class InvestmentIncomeReview
  LABELS = {
    dividends: "Dividend",
    interest: "Interest",
    contributions: "Contribution",
    withdrawals: "Withdrawal"
  }.freeze

  attr_reader :user, :period

  def initialize(user:, period:)
    @user = user
    @period = period
  end

  def family
    user.family
  end

  def currency
    family.currency
  end

  # Net of the signed entries for the label, expressed as a positive figure in
  # family currency. nil when any contributing entry lacks an exchange rate.
  def total(kind)
    totals.fetch(kind)
  end

  def income_total
    parts = [ total(:dividends), total(:interest) ]
    parts.any?(&:nil?) ? nil : parts.sum
  end

  def net_contributions
    parts = [ total(:contributions), total(:withdrawals) ]
    parts.any?(&:nil?) ? nil : total(:contributions) - total(:withdrawals)
  end

  def missing_fx_count
    missing_fx.values.sum
  end

  # Option premium has no verified, distinct source label in the ledger, so it
  # is never presented as a number.
  def option_premium_available?
    false
  end

  def accounts
    @accounts ||= begin
      scope = family.accounts.visible.included_in_reports.where(accountable_type: %w[Investment Crypto])
      scope.included_in_finances_for(user)
    end
  end

  def period_return_trend
    InvestmentStatement.new(family, user: user).period_return_trend(period: period)
  end

  private
    def totals
      compute
      @totals
    end

    def missing_fx
      compute
      @missing_fx
    end

    def compute
      return if @totals

      rows = Entry.joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
                  .where(account_id: accounts.select(:id), excluded: false, date: period.date_range)
                  .where(transactions: { investment_activity_label: LABELS.values })
                  .pluck("transactions.investment_activity_label", "entries.amount", "entries.currency", "entries.date")

      foreign = rows.map { |_, _, cur, _| cur }.uniq - [ currency ]
      rates = foreign.empty? ? {} : ExchangeRate.where(from_currency: foreign, to_currency: currency, date: rows.map(&:last).uniq)
                                                .pluck(:from_currency, :date, :rate).to_h { |from, date, rate| [ [ from, date ], rate ] }

      sums = LABELS.keys.index_with { BigDecimal("0") }
      @missing_fx = LABELS.keys.index_with { 0 }
      kind_for = LABELS.invert

      rows.each do |label, amount, cur, date|
        kind = kind_for.fetch(label)
        rate = cur == currency ? 1 : rates[[ cur, date ]]
        if rate.nil?
          @missing_fx[kind] += 1
        else
          sums[kind] += amount.to_d * rate.to_d
        end
      end

      @totals = LABELS.keys.index_with { |kind| @missing_fx[kind].positive? ? nil : sums[kind].abs }
    end
end
