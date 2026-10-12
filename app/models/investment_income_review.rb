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
  INFLOW_KINDS = %i[dividends interest contributions].freeze

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

  OPTION_PREMIUM_TAGS = {
    "SELL_TO_OPEN" => :sold_to_open,
    "BUY_TO_OPEN" => :bought_to_open,
    "BUY_TO_CLOSE" => :bought_to_close,
    "SELL_TO_CLOSE" => :sold_to_close
  }.freeze

  # Option premium cash flow from the broker's own open/close tags on each
  # activity. Amounts are the broker's signed, fee-inclusive cash figures
  # (credit positive, debit negative) and their signs are preserved, so a sale
  # whose fees exceed its proceeds or a reversal reduces the total instead of
  # being counted as income. Assignments, exercises and expirations carry no
  # premium amount and are not counted. This is cash premium, not realized
  # profit: an open short has not been closed out yet.
  #
  # Only activities that state the family currency are summed (the broker
  # supplies no FX rate, and a missing currency is unknown, not assumed). A
  # category containing any unusable activity is nil as a whole rather than a
  # partial sum, and the net is nil when any category is.
  def option_premium
    @option_premium ||= begin
      sums = OPTION_PREMIUM_TAGS.values.index_with { BigDecimal("0") }
      broken = OPTION_PREMIUM_TAGS.values.index_with { false }
      count = 0
      unconverted = 0

      option_activities.each do |activity|
        kind = OPTION_PREMIUM_TAGS[activity[:option_type]]
        code = activity.dig(:currency, :code).presence
        amount = begin
          BigDecimal(activity[:amount].to_s)
        rescue ArgumentError
          nil
        end

        if amount.nil? || code != currency
          broken[kind] = true
          unconverted += 1
        else
          sums[kind] += amount
          count += 1
        end
      end

      credits = %i[sold_to_open sold_to_close]
      shown = sums.to_h do |kind, sum|
        value = broken[kind] ? nil : (credits.include?(kind) ? sum : -sum)
        [ kind, value ]
      end
      net = broken.values.any? ? nil : sums.values.sum

      shown.merge(net: net, count: count, unconverted: unconverted)
    end
  end

  def option_premium_available?
    !option_premium[:net].nil?
  end

  def accounts
    @accounts ||= begin
      scope = family.accounts.visible.included_in_reports.where(accountable_type: %w[Investment Crypto])
      scope.included_in_finances_for(user)
    end
  end

  # Market movement for the period, or nil (unavailable). The shared statement
  # treats a missing exchange rate as parity and a period with no balance rows as
  # a measured zero; neither is acceptable here, so the review answers only when
  # every investment account is in the family currency and has balance rows in
  # the period.
  def period_return_trend
    return nil if accounts.none?
    return nil if accounts.where.not(currency: currency).exists?
    return nil unless Balance.where(account_id: accounts.select(:id), date: period.date_range).exists?

    InvestmentStatement.new(family, user: user).period_return_trend(period: period)
  end

  private
    def option_activities
      range = period.date_range

      SnaptradeAccount.linked_to(accounts.pluck(:id)).flat_map do |provider_account|
        Array(provider_account.raw_activities_payload).filter_map do |raw|
          activity = raw.respond_to?(:to_h) ? raw.to_h.with_indifferent_access : {}
          next unless OPTION_PREMIUM_TAGS.key?(activity[:option_type])

          date = begin
            Date.iso8601(activity[:trade_date].to_s[0, 10])
          rescue ArgumentError
            nil
          end
          activity if date && range.cover?(date)
        end
      end
    end

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

      # Ledger sign convention: money arriving in the account is negative
      # (dividends, interest, contributions) and money leaving is positive
      # (withdrawals). Signs are applied to the NET of each label, so a reversal
      # reduces the total and a net-negative total stays negative.
      @totals = LABELS.keys.index_with do |kind|
        next nil if @missing_fx[kind].positive?

        INFLOW_KINDS.include?(kind) ? -sums[kind] : sums[kind]
      end
    end
end
