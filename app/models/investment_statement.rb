require "digest/md5"

class InvestmentStatement
  include Monetizable

  monetize :total_contributions, :total_dividends, :total_interest, :unrealized_gains

  attr_reader :family, :user

  def initialize(family, user: nil)
    @family = family
    @user = user || Current.user
  end

  # Get totals for a specific period
  def totals(period: Period.current_month)
    account_ids = investment_account_ids

    trade_totals = totals_query(account_ids: account_ids, date_range: period.date_range)
    flow_totals = InvestmentFlowStatement.new(family, user: user).period_totals(period: period)

    PeriodTotals.new(
      contributions: flow_totals.contributions,
      withdrawals: flow_totals.withdrawals,
      dividends: Money.new(trade_totals[:dividends], family.currency),
      interest: Money.new(trade_totals[:interest], family.currency),
      trades_count: trade_totals[:trades_count],
      currency: family.currency
    )
  end

  # Net contributions (contributions - withdrawals)
  def net_contributions(period: Period.current_month)
    t = totals(period: period)
    t.contributions - t.withdrawals
  end

  # Total portfolio value across all investment accounts
  # nil (never a 1:1 guess) when any account needs an exchange rate we lack.
  def portfolio_value
    sum_converted(investment_accounts) { |a| [ a.balance, a.currency ] }
  end

  def portfolio_value_money
    value = portfolio_value
    value.nil? ? nil : Money.new(value, family.currency)
  end

  # Total cash in investment accounts
  def cash_balance
    sum_converted(investment_accounts) { |a| [ a.cash_balance, a.currency ] }
  end

  def cash_balance_money
    value = cash_balance
    value.nil? ? nil : Money.new(value, family.currency)
  end

  # Foreign currencies with no usable exchange rate. Any figure that would need
  # one is reported as unavailable rather than converted at a guessed 1:1.
  def missing_exchange_rates
    needed = (investment_accounts.map(&:currency) + Holding.where(account_id: investment_account_ids).distinct.pluck(:currency))
               .compact.uniq.reject { |currency| currency == family.currency }
    (needed - exchange_rates.keys).sort
  end

  # Total holdings value
  def holdings_value
    total, cash = portfolio_value, cash_balance
    total && cash ? total - cash : nil
  end

  def holdings_value_money
    value = holdings_value
    value.nil? ? nil : Money.new(value, family.currency)
  end

  # All current holdings across investment accounts. Holdings are returned in
  # their native currency; callers that aggregate across accounts must convert
  # to family currency via convert_to_family_currency.
  #
  # Memoized: top_holdings, allocation, unrealized_gains, unrealized_gains_trend,
  # and day_change each call this, so an unmemoized version ran the same
  # DISTINCT ON query up to 5x per dashboard/report request.
  def current_holdings
    @current_holdings ||= Holding::CurrentForInvestmentAccounts
      .new(investment_account_ids)
      .relation
      .includes(:security, :account)
  end

  # Top investments rolled up by security across accounts, ranked by
  # family-currency value. Weight is % of total portfolio (including cash).
  # Presence is gated on holdings totals — not Account#balance — so a stale
  # zero portfolio_value still surfaces real positions.
  def top_holdings(limit: 5)
    rolled_up = holdings_rolled_up_by_security
    return [] if rolled_up.empty?

    holdings_total = rolled_up.sum { |_, value, _| value }
    return [] if holdings_total.zero?

    total = weight_denominator(holdings_total)

    # Rank/limit on value first; only then compute cost-basis trends for the
    # rows that will be rendered (avoids avg_cost/trade lookups for the rest).
    rolled_up
      .first(limit)
      .map do |security, value, holdings|
        HoldingAllocation.new(
          security: security,
          amount: Money.new(value, family.currency),
          weight: total ? (value / total * 100).round(2) : nil,
          trend: combined_holding_trend(holdings)
        )
      end
  end

  # Investment accounts that carry a balance but no current holding rows (a
  # pension feed, a balance-only brokerage, a manually valued fund). They are
  # part of portfolio_value, so without a row of their own the listed weights
  # could never reach 100%. Value is nil (never 1:1) when the rate is missing;
  # unknown values rank last.
  def account_positions
    @account_positions ||= begin
      total = weight_denominator(holdings_rolled_up_by_security.sum { |_, value, _| value })

      balance_only_accounts
        .map do |account|
          value = convert_to_family_currency(account.balance, account.currency)
          AccountPosition.new(
            account: account,
            amount: value.nil? ? nil : Money.new(value, family.currency),
            weight: value&.positive? && total ? (value / total * 100).round(2) : nil
          )
        end
        .sort_by { |position| [ position.amount.nil? ? 1 : 0, -(position.amount&.amount || 0) ] }
    end
  end

  # Top holdings and account positions together, ranked by family-currency
  # value, for surfaces that list "where the portfolio is".
  def top_positions(limit: 5)
    (top_holdings(limit: limit) + account_positions)
      .sort_by { |position| [ position.amount_money.nil? ? 1 : 0, -(position.amount_money&.amount || 0) ] }
      .first(limit)
  end

  # Portfolio allocation by security (rolled up across accounts). Shares the
  # weight denominator with top_holdings so the same security never reports two
  # different percentages. Weights therefore sum to the invested share of the
  # portfolio, not to 100 — cash is the residual.
  def allocation
    rolled_up = holdings_rolled_up_by_security
    holdings_total = rolled_up.sum { |_, value, _| value }
    return [] if holdings_total.zero?

    total = weight_denominator(holdings_total)

    rolled_up.map do |security, value, holdings|
      HoldingAllocation.new(
        security: security,
        amount: Money.new(value, family.currency),
        weight: total ? (value / total * 100).round(2) : nil,
        trend: combined_holding_trend(holdings)
      )
    end
  end

  # Unrealized gains across all holdings, summed in family currency
  def unrealized_gains
    sum_converted(current_holdings) do |holding|
      trend = holding.trend
      [ trend ? trend.value : 0, holding.currency ]
    end
  end

  # Total contributions (all time) - returns numeric for monetize
  def total_contributions
    all_time_totals.contributions&.amount || 0
  end

  # Total dividends (all time) - returns numeric for monetize
  def total_dividends
    all_time_totals.dividends&.amount || 0
  end

  # Total interest (all time) - returns numeric for monetize
  def total_interest
    all_time_totals.interest&.amount || 0
  end

  def unrealized_gains_trend
    holdings = current_holdings.to_a
    return nil if holdings.empty?

    # Only include holdings with known cost basis in the calculation
    holdings_with_cost_basis = holdings.select(&:avg_cost)
    return nil if holdings_with_cost_basis.empty?

    current = sum_converted(holdings_with_cost_basis) { |h| [ h.amount, h.currency ] }
    previous = sum_converted(holdings_with_cost_basis) { |h| [ h.qty * h.avg_cost.amount, h.currency ] }
    return nil if current.nil? || previous.nil?

    Trend.new(
      current: Money.new(current, family.currency),
      previous: Money.new(previous, family.currency)
    )
  end

  def period_return_trend(period: Period.current_month)
    currency = family.currency
    account_ids = investment_account_ids
    return nil if account_ids.empty?

    absolute_return = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT CASE WHEN BOOL_OR(b.currency <> :currency AND er.rate IS NULL) THEN NULL
                      ELSE COALESCE(SUM(b.net_market_flows * CASE WHEN b.currency = :currency THEN 1 ELSE er.rate END), 0) END
          FROM balances b
          JOIN accounts a ON a.id = b.account_id
          LEFT JOIN LATERAL (
            SELECT rate FROM exchange_rates
            WHERE from_currency = b.currency AND to_currency = :currency
              AND date BETWEEN b.date - 5 AND b.date
            ORDER BY date DESC LIMIT 1
          ) er ON true
          WHERE a.id IN (:account_ids)
            AND a.family_id = :family_id
            AND a.status IN ('draft', 'active')
            AND b.date BETWEEN :start_date AND :end_date
        SQL
        {
          currency: currency,
          account_ids: account_ids,
          family_id: family.id,
          start_date: period.date_range.begin,
          end_date: period.date_range.end
        }
      ])
    )
    return nil if absolute_return.nil?
    absolute_return = absolute_return.to_d

    period_start = period.date_range.begin

    # Single query for all accounts' most recent pre-period balance (strict < to avoid
    # double-counting the first day's net_market_flows in both the denominator and absolute_return).
    # FX conversion is done in SQL (matching absolute_return) so balance rows whose currency
    # differs from the account's current currency (e.g. after a currency change) are still picked up.
    start_value = ActiveRecord::Base.connection.select_value(
      ActiveRecord::Base.sanitize_sql_array([
        <<~SQL.squish,
          SELECT CASE WHEN BOOL_OR(b.currency <> :currency AND er.rate IS NULL) THEN NULL
                      ELSE COALESCE(SUM(b.end_balance * CASE WHEN b.currency = :currency THEN 1 ELSE er.rate END), 0) END
          FROM accounts a
          INNER JOIN balances b ON b.account_id = a.id
          LEFT JOIN LATERAL (
            SELECT rate FROM exchange_rates
            WHERE from_currency = b.currency AND to_currency = :currency
              AND date BETWEEN (:period_start)::date - 5 AND (:period_start)::date
            ORDER BY date DESC LIMIT 1
          ) er ON true
          INNER JOIN (
            SELECT b2.account_id, MAX(b2.date) AS max_date
            FROM balances b2
            WHERE b2.account_id IN (:account_ids)
              AND b2.date < :period_start
            GROUP BY b2.account_id
          ) latest ON latest.account_id = b.account_id AND b.date = latest.max_date
          WHERE a.id IN (:account_ids)
            AND a.family_id = :family_id
            AND a.status IN ('draft', 'active')
        SQL
        { account_ids: account_ids, period_start: period_start, family_id: family.id, currency: currency }
      ])
    )
    return nil if start_value.nil?
    start_value = start_value.to_d


    return nil if start_value.zero?

    Trend.new(
      current: Money.new(start_value + absolute_return, currency),
      previous: Money.new(start_value, currency)
    )
  end

  # Day change across portfolio, summed in family currency
  def day_change
    all = current_holdings.to_a
    batched = Holding::DayChange.for(all)
    changes = all.filter_map do |h|
      t = batched[h.id]
      next nil unless t
      curr = t.current.is_a?(Money) ? t.current.amount : t.current
      prev = t.previous.is_a?(Money) ? t.previous.amount : t.previous
      [
        convert_to_family_currency(curr, h.currency),
        convert_to_family_currency(prev, h.currency)
      ]
    end

    return nil if changes.empty? || changes.flatten.any?(&:nil?)

    Trend.new(
      current: Money.new(changes.sum { |c, _| c }, family.currency),
      previous: Money.new(changes.sum { |_, p| p }, family.currency)
    )
  end

  # Investment accounts
  def investment_accounts
    @investment_accounts ||= begin
      scope = family.accounts.visible.included_in_reports.where(accountable_type: %w[Investment Crypto])
      scope = scope.included_in_finances_for(user) if user
      scope
    end
  end

  private
    # Today's rates for every currency present on the family's investment
    # accounts and their holdings. Mirrors BalanceSheet::AccountTotals#exchange_rates.
    def exchange_rates
      @exchange_rates ||= begin
        account_currencies = investment_accounts.map(&:currency)
        holding_currencies = Holding.where(account_id: investment_account_ids).distinct.pluck(:currency)
        foreign = (account_currencies + holding_currencies)
                    .compact
                    .uniq
                    .reject { |c| c == family.currency }
        ExchangeRate.rates_for(foreign, to: family.currency, date: Date.current, fallback: nil).compact
      end
    end

    # Unwrap Money first because this codebase's Money (lib/money.rb) ignores
    # the currency arg of `Money.new` when the payload is already a Money, and
    # `Money * numeric` preserves the source currency — so multiplying a
    # foreign-currency Money by a rate would FX-scale the amount but keep the
    # wrong currency label, corrupting downstream sums.
    def convert_to_family_currency(amount, from_currency)
      return amount if amount.nil?
      numeric = amount.is_a?(Money) ? amount.amount : amount
      return numeric if from_currency == family.currency
      rate = exchange_rates[from_currency]
      rate.nil? ? nil : numeric * rate
    end

    # Sum converted values; one unconvertible value makes the whole total unknown.
    def sum_converted(items)
      values = items.map { |item| convert_to_family_currency(*yield(item)) }
      values.any?(&:nil?) ? nil : values.sum
    end

    def all_time_totals
      @all_time_totals ||= totals(period: Period.all_time)
    end

    PeriodTotals = Data.define(:contributions, :withdrawals, :dividends, :interest, :trades_count, :currency) do
      def net_flow
        contributions - withdrawals
      end

      def total_income
        dividends + interest
      end
    end

    HoldingAllocation = Data.define(:security, :amount, :weight, :trend) do
      def ticker = security.ticker
      def name = security.name.presence || ticker
      def amount_money = amount
      def account_position? = false
    end

    AccountPosition = Data.define(:account, :amount, :weight) do
      def name = account.name
      def amount_money = amount
      def trend = nil
      def account_position? = true
      def liability? = amount&.amount&.negative? || false
    end

    # Groups current holdings by security and sums family-currency value.
    # Returns [[security, value, holdings], ...] sorted by value descending.
    # Callers that need return trends should call combined_holding_trend only
    # for rows they will render (e.g. after top_holdings applies its limit).
    # Shared by top_holdings and allocation so one security cannot report two
    # different percentages.
    #
    # max(portfolio_value, holdings_total) rather than portfolio_value alone:
    # portfolio_value includes cash, which goes negative on margin or an
    # unsettled buy and would push a weight past 100%. The holdings total acts
    # as a floor. It also covers a stale-zero portfolio_value, where the cached
    # Account#balance lags behind the Holding rows.
    def weight_denominator(holdings_total)
      total = portfolio_value
      total.nil? ? nil : [ total, holdings_total, holdings_total + balance_only_accounts_total ].max
    end

    # Investment accounts with a non-zero balance and no current holding rows.
    # Negative balances are debit/liability positions: they reconcile the
    # portfolio total but do not receive an allocation percentage.
    def balance_only_accounts
      @balance_only_accounts ||= begin
        held_account_ids = current_holdings.map(&:account_id).to_set
        investment_accounts.reject { |account| held_account_ids.include?(account.id) || account.balance.to_d.zero? }
      end
    end

    # Floor for the weight denominator. A missing rate makes portfolio_value
    # (and so every weight) nil anyway, so an unconvertible balance counts 0.
    def balance_only_accounts_total
      balance_only_accounts.sum(0.to_d) { |account| convert_to_family_currency(account.balance, account.currency) || 0 }
    end

    def holdings_rolled_up_by_security
      current_holdings
        .to_a
        .group_by(&:security_id)
        .filter_map do |_security_id, holdings|
          # Filter row by row rather than on the netted total. current_holdings
          # is DISTINCT ON (account_id, security_id), so one security held in two
          # accounts yields two rows; a negative row in one would otherwise net
          # against the good row in the other and understate the position.
          positive_holdings = holdings.select do |holding|
            converted = convert_to_family_currency(holding.amount, holding.currency)
            converted && converted.positive?
          end
          next if positive_holdings.empty?

          security = positive_holdings.first.security
          value = sum_converted(positive_holdings) { |h| [ h.amount, h.currency ] }

          # positive_holdings, not holdings, so the trend excludes the bad row too.
          [ security, value, positive_holdings ]
        end
        .sort_by { |_, value, _| -value }
    end

    def combined_holding_trend(holdings)
      currents = []
      previouses = []

      holdings.each do |holding|
        trend = holding.trend
        next unless trend

        currents << convert_to_family_currency(trend.current, holding.currency)
        previouses << convert_to_family_currency(trend.previous, holding.currency)
      end

      return nil if currents.empty? || currents.any?(&:nil?) || previouses.any?(&:nil?)

      Trend.new(
        current: Money.new(currents.sum, family.currency),
        previous: Money.new(previouses.sum, family.currency)
      )
    end

    def investment_account_ids
      @investment_account_ids ||= investment_accounts.pluck(:id)
    end

    def totals_query(account_ids:, date_range:)
      if account_ids.empty?
        return Totals.new(family, account_ids: account_ids, date_range: date_range).call
      end

      account_ids_hash = Digest::MD5.hexdigest(account_ids.sort.join(","))

      Rails.cache.fetch([
        "investment_statement", "totals_query", family.id, user&.id,
        account_ids_hash, date_range.begin, date_range.end, family.entries_cache_version
      ]) { Totals.new(family, account_ids: account_ids, date_range: date_range).call }
    end

    def monetizable_currency
      family.currency
    end
end
