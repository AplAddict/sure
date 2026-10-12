# Realized gains and losses from sales in the accounts a user can access.
#
# Every figure comes from Trade#realized_gain_loss (proceeds against the
# position's average cost on the sale date), converted at the exchange rate of
# the day of the sale. A sale that cannot be measured is excluded and counted
# with its reason, never folded in as a zero gain or converted at a guessed 1:1.
# Moving a position to another account you own realizes nothing.
class RealizedGainsReview
  Month = Data.define(:month, :gains, :losses, :trade_count) do
    def net = gains - losses
  end

  attr_reader :user, :period

  def initialize(user:, period:)
    @user = user
    @period = period
  end

  def family = user.family
  def currency = family.currency

  def gains = outcome[:gains]
  def losses = outcome[:losses]
  def net = gains - losses
  def measured_count = outcome[:measured]
  def excluded_count = outcome[:excluded].values.sum
  def excluded_reasons = outcome[:excluded].dup
  def partial? = excluded_count.positive?
  def monthly = outcome[:months].values.sort_by(&:month)

  def accounts
    @accounts ||= family.accounts.visible.included_in_reports.where(accountable_type: %w[Investment Crypto]).included_in_finances_for(user)
  end

  private
    def outcome
      @outcome ||= compute
    end

    def compute
      gains = BigDecimal("0")
      losses = BigDecimal("0")
      measured = 0
      excluded = Hash.new(0)
      months = {}

      trades.each do |trade|
        next if trade.internal_movement?

        gain = trade.realized_gain_loss
        if gain.nil?
          excluded[basis_known?(trade) ? :no_exchange_rate : :no_cost_basis] += 1
          next
        end

        value = gain.value
        rate = rate_for(value.currency.iso_code, trade.entry.date)
        if rate.nil?
          excluded[:no_exchange_rate] += 1
          next
        end

        amount = value.amount.to_d * rate
        month = trade.entry.date.beginning_of_month
        bucket = months[month] || Month.new(month: month, gains: BigDecimal("0"), losses: BigDecimal("0"), trade_count: 0)
        bucket = amount.positive? ? bucket.with(gains: bucket.gains + amount) : bucket.with(losses: bucket.losses - amount)
        months[month] = bucket.with(trade_count: bucket.trade_count + 1)

        amount.positive? ? gains += amount : losses -= amount
        measured += 1
      end

      { gains: gains, losses: losses, measured: measured, excluded: excluded.to_h.symbolize_keys, months: months }
    end

    def trades
      @trades ||= begin
        rows = Trade.joins(:entry).includes(:security, entry: :account)
                    .where(entries: { account_id: accounts.select(:id), excluded: false, date: period.date_range })
                    .where("trades.qty < 0").to_a
        holdings = Holding.where(account_id: rows.map { |trade| trade.entry.account_id }.uniq, security_id: rows.map(&:security_id).uniq)
                          .group_by(&:account_id)
        rows.each { |trade| trade.preloaded_holdings = holdings.fetch(trade.entry.account_id, []) if trade.respond_to?(:preloaded_holdings=) }
        rows
      end
    end

    def basis_known?(trade)
      Holding.where(account_id: trade.entry.account_id, security_id: trade.security_id)
             .where("date <= ?", trade.entry.date).order(date: :desc).first&.avg_cost.present?
    end

    def rate_for(from, date)
      return BigDecimal("1") if from == currency

      @rates ||= {}
      @rates.fetch([ from, date ]) do
        rate = ExchangeRate.find_by(from_currency: from, to_currency: currency, date: date)&.rate
        @rates[[ from, date ]] = rate && rate.to_d.positive? ? rate.to_d : nil
      end
    end
end
