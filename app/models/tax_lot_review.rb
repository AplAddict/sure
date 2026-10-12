# Read-only, per-lot view of unrealized gains and losses in taxable accounts,
# split by holding period, plus the lots about to cross into long-term.
#
# This is date and arithmetic only. It applies no tax rates, estimates no tax
# owed and recommends no action. Lots come exclusively from the broker's own
# tax-lot records (via PortfolioHoldings, which drops any lot set that does not
# add up to the held position); a lot missing its acquisition date, basis or
# value is counted as unmeasured and never as zero. Scoped to the accounts the
# user can access, and only taxable ones (gains elsewhere are not taxed on
# realization).
class TaxLotReview
  # Matches TaxLossHarvest: held MORE than this many days is long-term.
  LONG_TERM_DAYS = TaxLossHarvest::LONG_TERM_DAYS
  DEFAULT_WINDOW_DAYS = 60

  Lot = Data.define(:account, :security, :acquired_on, :quantity, :cost_basis, :market_value, :currency, :term, :days_to_long_term) do
    def ticker = security.ticker
    def gain = market_value - cost_basis
    def gain_pct = cost_basis.positive? ? gain / cost_basis * 100 : nil
  end

  attr_reader :user, :today, :window_days

  def initialize(user:, today: Date.current, window_days: DEFAULT_WINDOW_DAYS)
    @user = user
    @today = today
    @window_days = window_days
  end

  def family = user.family
  def currency = family.currency

  def lots
    build unless defined?(@lots)
    @lots
  end

  def unmeasured_count
    build unless defined?(@unmeasured_count)
    @unmeasured_count
  end

  def excluded_account_count
    portfolio.accounts.count { |account| account.tax_treatment != :taxable }
  end

  # Short-term lots that become long-term within the window, soonest first.
  def approaching_long_term
    lots.select { |lot| lot.term == :short && lot.days_to_long_term <= window_days }
        .sort_by { |lot| [ lot.days_to_long_term, lot.ticker ] }
  end

  # Unrealized totals by holding period, gains and losses kept separate so
  # neither is netted away. Family-currency lots only.
  def totals
    @totals ||= begin
      sums = { short_gain: BigDecimal("0"), short_loss: BigDecimal("0"), long_gain: BigDecimal("0"), long_loss: BigDecimal("0") }
      lots.each do |lot|
        key = "#{lot.term}_#{lot.gain.negative? ? 'loss' : 'gain'}".to_sym
        sums[key] += lot.gain.abs
      end
      sums
    end
  end

  private
    def portfolio
      @portfolio ||= PortfolioHoldings.new(user: user)
    end

    def build
      @lots = []
      @unmeasured_count = 0
      taxable = portfolio.accounts.select { |account| account.tax_treatment == :taxable }.map(&:id)

      portfolio.blocks.each do |block|
        next unless taxable.include?(block.account.id)

        block.positions.each do |position|
          position.lots.each do |lot|
            if lot.acquired_on.nil? || lot.cost_basis.nil? || lot.market_value.nil? || block.currency != currency
              @unmeasured_count += 1
              next
            end

            held_days = (today - lot.acquired_on).to_i
            term = held_days > LONG_TERM_DAYS ? :long : :short
            @lots << Lot.new(
              account: block.account, security: position.security, acquired_on: lot.acquired_on, quantity: lot.quantity,
              cost_basis: lot.cost_basis, market_value: lot.market_value, currency: block.currency, term: term,
              days_to_long_term: term == :short ? LONG_TERM_DAYS + 1 - held_days : nil
            )
          end
        end
      end
    end
end
