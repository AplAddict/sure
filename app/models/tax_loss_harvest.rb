# Read-only tax-loss-harvest projection for ONE signed-in user.
#
# Scope is the user's own accessible accounts (owned + shared with them), never
# the whole family: a family member must not learn what another member holds.
# Nothing here writes to holdings, trades, entries or brokers.
#
# Honesty rules, mirrored from the rest of the investing surface:
#   * A holding with unknown cost basis, or a foreign-currency value with no
#     stored exchange rate, is listed as "unavailable" and left out of every
#     total. It is never counted as a zero loss and never as a zero gain.
#   * Sure keeps one aggregate row per account/security, not broker tax lots,
#     so holding period is an estimate rebuilt from recorded trades (FIFO) and
#     is "unknown" whenever the trade history cannot account for the quantity.
#   * Wash-sale checks run across EVERY account the user can see, including
#     tax-advantaged ones, because the rule follows the taxpayer, not the
#     account. They are flags to review, not tax advice.
class TaxLossHarvest
  # A position is a "candidate" once the loss passes this share of its cost.
  CANDIDATE_LOSS_PCT = BigDecimal("5")
  LONG_TERM_DAYS = 365
  WASH_WINDOW_DAYS = 30
  QTY_TOLERANCE = BigDecimal("0.000001")
  TAXABLE_TYPES = %w[Investment Crypto].freeze

  Row = Data.define(
    :account, :security, :qty, :market_value, :cost_basis, :loss, :loss_pct,
    :candidate, :term, :short_term_qty, :long_term_qty, :first_acquired,
    :wash_flags
  ) do
    def ticker = security.ticker
    def name = security.name.presence || security.ticker
  end

  # kind: :recent_purchase | :held_elsewhere | :open_window
  WashFlag = Data.define(:kind, :date, :end_date, :detail)

  Unavailable = Data.define(:account, :security, :reason) do
    def ticker = security.ticker
    def name = security.name.presence || security.ticker
  end

  Totals = Data.define(
    :loss, :short_term_loss, :long_term_loss, :unknown_term_loss,
    :candidate_count, :loss_count, :currency
  )

  attr_reader :user, :today

  def initialize(user:, today: Date.current)
    @user = user
    @today = today
  end

  def family = user.family
  def currency = family.currency

  # Taxable accounts the user can see; the only ones where a realized loss
  # offsets anything.
  def accounts
    @accounts ||= visible_accounts.select { |account| account.tax_treatment == :taxable }
  end

  # Visible accounts that were left out because gains/losses are not taxed on
  # realization there (IRA, Roth, 401k, ...). Shown so the omission is explicit.
  def excluded_account_count
    visible_accounts.size - accounts.size
  end

  def rows
    build unless defined?(@rows)
    @rows
  end

  def unavailable
    build unless defined?(@unavailable)
    @unavailable
  end

  def candidates
    rows.select(&:candidate)
  end

  def totals
    @totals ||= begin
      zero = BigDecimal("0")
      by_term = rows.group_by(&:term)
      sum = ->(list) { list.sum(zero) { |row| row.loss.amount.abs } }
      Totals.new(
        loss: Money.new(sum.call(rows), currency),
        short_term_loss: Money.new(sum.call(by_term.fetch(:short, [])), currency),
        long_term_loss: Money.new(sum.call(by_term.fetch(:long, []) + by_term.fetch(:mixed, [])), currency),
        unknown_term_loss: Money.new(sum.call(by_term.fetch(:unknown, [])), currency),
        candidate_count: candidates.size,
        loss_count: rows.size,
        currency: currency
      )
    end
  end

  # Realized gain/loss on sales so far this calendar year in the same taxable
  # accounts. Returns { amount: Money, known: n, unknown: n }. Harvested losses
  # offset exactly these gains first, so it frames how much harvesting is worth.
  def realized_year_to_date
    @realized_year_to_date ||= begin
      sells = year_sell_trades
      known = 0
      unknown = 0
      total = BigDecimal("0")

      sells.each do |trade|
        gain = trade.realized_gain_loss
        converted = gain && to_family_currency(gain.value, trade.entry.date)
        if converted
          known += 1
          total += converted.amount
        else
          unknown += 1
        end
      end

      { amount: Money.new(total, currency), known: known, unknown: unknown }
    end
  end

  private
    def visible_accounts
      @visible_accounts ||= user.accessible_accounts
        .visible
        .where(accountable_type: TAXABLE_TYPES)
        .includes(:accountable)
        .to_a
    end

    # Every account the user can see that holds securities, regardless of tax
    # treatment: the wash-sale rule counts purchases in an IRA too.
    def all_trade_account_ids
      @all_trade_account_ids ||= user.accessible_accounts.visible.pluck(:id)
    end

    def build
      @rows = []
      @unavailable = []

      accounts.each do |account|
        account.current_holdings.includes(:security).each do |holding|
          next unless holding.security
          row_or_reason = evaluate(account, holding)
          case row_or_reason
          when Row then @rows << row_or_reason
          when Unavailable then @unavailable << row_or_reason
          end
        end
      end

      @rows.sort_by! { |row| row.loss.amount }
      @unavailable.sort_by!(&:ticker)
    end

    # Returns a Row for a losing position, an Unavailable when the position
    # cannot be measured, or nil when it is measurable and not at a loss.
    def evaluate(account, holding)
      qty = holding.qty.to_d
      return nil unless qty.positive?

      avg_cost = holding.avg_cost
      return Unavailable.new(account, holding.security, :cost_basis_unknown) if avg_cost.nil?

      market_value = holding.amount_money
      cost_basis = avg_cost * qty
      # Same currency by construction (holding currency); compare as numbers.
      gain_amount = market_value.amount - cost_basis.amount
      return nil unless gain_amount.negative?

      loss_local = Money.new(gain_amount, holding.currency)
      loss = to_family_currency(loss_local, today)
      return Unavailable.new(account, holding.security, :exchange_rate_missing) if loss.nil?

      value_family = to_family_currency(market_value, today)
      cost_family = to_family_currency(cost_basis, today)
      return Unavailable.new(account, holding.security, :exchange_rate_missing) if value_family.nil? || cost_family.nil?

      loss_pct = cost_basis.amount.positive? ? (gain_amount / cost_basis.amount * 100).round(2) : nil
      lots = holding_period(account, holding)

      Row.new(
        account: account,
        security: holding.security,
        qty: qty,
        market_value: value_family,
        cost_basis: cost_family,
        loss: loss,
        loss_pct: loss_pct,
        candidate: loss_pct.present? && loss_pct.abs >= CANDIDATE_LOSS_PCT,
        term: lots[:term],
        short_term_qty: lots[:short_qty],
        long_term_qty: lots[:long_qty],
        first_acquired: lots[:first_acquired],
        wash_flags: wash_flags_for(account, holding.security)
      )
    end

    def to_family_currency(money, date)
      money.exchange_to(currency, date: date)
    rescue Money::ConversionError
      nil
    end

    # FIFO reconstruction from recorded trades. Returns term :short, :long,
    # :mixed or :unknown. Unknown whenever an internal movement is involved or
    # the recorded history does not add up to the held quantity, because a
    # guessed acquisition date would be a fabricated tax fact.
    def holding_period(account, holding)
      trades = trades_by_account_security.fetch([ account.id, holding.security_id ], [])
      unknown = { term: :unknown, short_qty: nil, long_qty: nil, first_acquired: nil }
      return unknown if trades.empty?
      return unknown if trades.any?(&:internal_movement?)

      lots = []
      trades.each do |trade|
        quantity = trade.qty.to_d
        if quantity.positive?
          lots << [ trade.entry.date, quantity ]
        else
          remaining = quantity.abs
          while remaining.positive? && lots.any?
            take = [ lots.first[1], remaining ].min
            lots.first[1] -= take
            remaining -= take
            lots.shift if lots.first[1] <= QTY_TOLERANCE
          end
          return unknown if remaining > QTY_TOLERANCE
        end
      end

      held = lots.sum(BigDecimal("0")) { |_date, quantity| quantity }
      return unknown if (held - holding.qty.to_d).abs > [ holding.qty.to_d * BigDecimal("0.001"), QTY_TOLERANCE ].max

      long_qty = lots.select { |date, _| (today - date).to_i > LONG_TERM_DAYS }.sum(BigDecimal("0")) { |_d, q| q }
      short_qty = held - long_qty
      term = if long_qty <= QTY_TOLERANCE then :short
      elsif short_qty <= QTY_TOLERANCE then :long
      else :mixed
      end

      { term: term, short_qty: short_qty, long_qty: long_qty, first_acquired: lots.map(&:first).min }
    end

    def trades_by_account_security
      @trades_by_account_security ||= begin
        account_ids = accounts.map(&:id)
        Trade.joins(:entry)
          .where(entries: { account_id: account_ids })
          .includes(:entry)
          .order("entries.date ASC, entries.created_at ASC")
          .group_by { |trade| [ trade.entry.account_id, trade.security_id ] }
      end
    end

    # Purchases of the same security in the 30 days before today (selling now
    # would disallow the loss on those shares), holdings of it in any other
    # account the user can see, and an open wash-sale window from an earlier
    # loss sale.
    def wash_flags_for(account, security)
      flags = []

      recent = recent_buys_by_security.fetch(security.id, [])
      if recent.any?
        last = recent.max_by { |trade| trade.entry.date }
        flags << WashFlag.new(
          kind: :recent_purchase,
          date: last.entry.date,
          end_date: last.entry.date + WASH_WINDOW_DAYS.days,
          detail: recent.sum(BigDecimal("0")) { |trade| trade.qty.to_d }
        )
      end

      elsewhere = held_elsewhere.fetch(security.id, []).reject { |name, id| id == account.id }
      flags << WashFlag.new(kind: :held_elsewhere, date: nil, end_date: nil, detail: elsewhere.map(&:first).uniq.sort) if elsewhere.any?

      window = open_windows.find { |event| event.ticker == security.ticker }
      flags << WashFlag.new(kind: :open_window, date: window.date, end_date: window.end_date, detail: nil) if window

      flags
    end

    def recent_buys_by_security
      @recent_buys_by_security ||= Trade.joins(:entry)
        .where(entries: { account_id: all_trade_account_ids, date: (today - WASH_WINDOW_DAYS.days)..today })
        .where("trades.qty > 0")
        .includes(:entry)
        .group_by(&:security_id)
    end

    def held_elsewhere
      @held_elsewhere ||= user.accessible_accounts.visible.includes(:accountable).flat_map do |account|
        account.current_holdings.map { |holding| [ holding.security_id, [ account.name, account.id ] ] }
      end.group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    end

    def open_windows
      @open_windows ||= MarketCalendar::EventBuilder.new(accounts: user.accessible_accounts.visible, now: today.to_time)
        .events
        .select { |event| event.event_type == "wash_sale" && event.date <= today && event.end_date >= today }
    end

    def year_sell_trades
      @year_sell_trades ||= begin
        range = today.beginning_of_year..today
        trades = Trade.joins(:entry)
          .where(entries: { account_id: accounts.map(&:id), date: range })
          .where("trades.qty < 0")
          .where("trades.investment_activity_label IS NULL OR trades.investment_activity_label NOT IN (?)", Trade::INTERNAL_MOVEMENT_LABELS)
          .includes(:security, entry: { account: :accountable })
          .to_a

        holdings_by_account = Holding.where(account_id: trades.map { |trade| trade.entry.account_id }.uniq)
          .where("date <= ?", today)
          .order(date: :desc)
          .group_by(&:account_id)
        trades.each { |trade| trade.instance_variable_set(:@preloaded_holdings, holdings_by_account[trade.entry.account_id] || []) }
        Trade.preload_exchange_rates(trades)
        trades
      end
    end
end
