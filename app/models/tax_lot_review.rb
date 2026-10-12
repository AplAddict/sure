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
  DEFAULT_WINDOW_DAYS = 60

  Lot = Data.define(:account, :security, :acquired_on, :quantity, :cost_basis, :market_value, :currency, :term, :days_to_long_term) do
    def ticker = security.ticker
    def gain = market_value - cost_basis
    def gain_pct = cost_basis.positive? ? gain / cost_basis * 100 : nil
  end

  # An open taxable position with no usable lot set, and why. :provider_supplies_none
  # means the account's source sends no lots; :broker_lots_unusable means a
  # SnapTrade-linked account whose lots were missing or did not add up to the
  # held quantity.
  Gap = Data.define(:account, :security, :reason)

  CASH_SWEEP_NAME = /money\s*market/i

  SORTS = %w[ticker account acquired term quantity cost_basis market_value gain].freeze
  TERMS = %w[short long].freeze
  CSV_HEADERS = [ "Ticker", "Account", "Acquired", "Term", "Quantity", "Cost basis", "Market value", "Unrealized gain/loss", "Currency" ].freeze

  attr_reader :user, :today, :window_days, :ticker, :term, :sort, :direction

  def initialize(user:, today: Date.current, window_days: DEFAULT_WINDOW_DAYS, ticker: nil, term: nil, sort: nil, direction: nil)
    @user = user
    @today = today
    @window_days = window_days
    @ticker = ticker.to_s.strip.upcase.gsub(/[^A-Z0-9.\-]/, "").presence&.first(20)
    @term = TERMS.include?(term.to_s) ? term.to_s : nil
    @sort = SORTS.include?(sort.to_s) ? sort.to_s : "ticker"
    @direction = direction.to_s == "desc" ? "desc" : "asc"
  end

  def filtered? = ticker.present? || term.present?

  # The lots table: filtered by ticker and holding period, then sorted. The
  # totals above it always cover every measured lot, so a filter narrows what
  # is listed and never changes a headline figure.
  def visible_lots
    @visible_lots ||= begin
      list = lots
      list = list.select { |lot| lot.ticker.upcase.include?(ticker) } if ticker
      list = list.select { |lot| lot.term.to_s == term } if term
      ordered = list.sort_by { |lot| [ sort_value(lot), lot.ticker, lot.acquired_on ] }
      direction == "desc" ? ordered.reverse : ordered
    end
  end

  # Spreadsheet-safe CSV of the lots currently shown. Text that a spreadsheet
  # would read as a formula is prefixed with an apostrophe.
  def to_csv
    require "csv"
    CSV.generate do |csv|
      csv << CSV_HEADERS
      visible_lots.each do |lot|
        csv << [ lot.ticker, lot.account.name, lot.acquired_on.iso8601, lot.term.to_s, lot.quantity.to_s("F"), lot.cost_basis.to_s("F"),
                 lot.market_value.to_s("F"), lot.gain.to_s("F"), lot.currency ].map { |value| self.class.csv_safe(value) }
      end
    end
  end

  FORMULA_START = /\A[=+\-@\t\r]/

  def self.csv_safe(value)
    text = value.to_s
    text.match?(FORMULA_START) ? "'#{text}" : text
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

  # Open positions in taxable accounts for which the broker supplied no lot set
  # that adds up to the held quantity. They are absent from every figure, so the
  # page reports them instead of letting "no lots" look like "nothing to review".
  def positions_without_lots = lot_gaps.size

  def lot_gaps
    build unless defined?(@lot_gaps)
    @lot_gaps
  end

  # Money-market sweeps held at $1 a share. They have no meaningful gain to
  # measure by lot, so they are listed apart and not reported as a data gap.
  def cash_sweeps
    build unless defined?(@cash_sweeps)
    @cash_sweeps
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
      @lot_gaps = []
      @cash_sweeps = []
      snaptrade_ids = portfolio.snaptrade_account_ids
      taxable = portfolio.accounts.select { |account| account.tax_treatment == :taxable }.map(&:id)

      portfolio.blocks.each do |block|
        next unless taxable.include?(block.account.id)

        block.positions.each do |position|
          if position.lots.empty?
            if cash_sweep?(position)
              @cash_sweeps << position
            else
              reason = snaptrade_ids.include?(block.account.id) ? :broker_lots_unusable : :provider_supplies_none
              @lot_gaps << Gap.new(account: block.account, security: position.security, reason: reason)
            end
          end

          position.lots.each do |lot|
            long_term = HoldingPeriod.long_term?(lot.acquired_on, today)
            measurable = !long_term.nil? && lot.cost_basis && lot.market_value && position.currency == currency
            unless measurable
              @unmeasured_count += 1
              next
            end

            term = long_term ? :long : :short
            @lots << Lot.new(
              account: block.account, security: position.security, acquired_on: lot.acquired_on, quantity: lot.quantity,
              cost_basis: lot.cost_basis, market_value: lot.market_value, currency: position.currency, term: term,
              days_to_long_term: HoldingPeriod.days_to_long_term(lot.acquired_on, today)
            )
          end
        end
      end
    end

    def sort_value(lot)
      case sort
      when "ticker" then lot.ticker
      when "account" then lot.account.name.downcase
      when "acquired" then lot.acquired_on
      when "term" then lot.term.to_s
      when "quantity" then lot.quantity
      when "cost_basis" then lot.cost_basis
      when "market_value" then lot.market_value
      when "gain" then lot.gain
      end
    end

    def cash_sweep?(position)
      position.price == 1 && position.security.name.to_s.match?(CASH_SWEEP_NAME)
    end
end
