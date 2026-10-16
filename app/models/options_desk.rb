# Read-only, account-scoped options desk data. It joins global quotes only after
# the caller's SnapTrade positions have been selected.
class OptionsDesk
  EXPIRING_SOON_DAYS = 7

  Result = Data.define(:rows, :groups, :summary, :ideas, :invalid_account_scope, :source_state, :contexts)
  Row = Data.define(:account_id, :account_name, :account_currency, :contract, :underlying, :option_type, :expiration, :strike,
                    :quantity, :multiplier, :side, :currency, :broker_mark, :broker_snapshot_current, :broker_synced_at,
                    :quote, :quote_as_of, :mark, :mark_value_signed, :entry_basis_total, :total_pnl, :day_gain, :model_delta,
                    :position_delta, :evidence_status, :evidence_reason)
  Group = Data.define(:underlying, :rows, :total_pnl, :currency, :unavailable_count)
  Summary = Data.define(:contract_count, :expiring_soon_count, :expired_count, :current_mark_count, :indicative_count,
                        :unavailable_count, :total_pnl, :total_pnl_currency, :day_pnl, :total_position_delta,
                        :position_delta_exclusion_count, :unreadable_source_count)
  Ideas = Data.define(:covered_calls, :puts)

  def initialize(user:, account_id: nil, now: Time.current)
    @user = user
    @account_id = account_id
    @now = now
  end

  def result
    @result ||= build_result
  end

  private

    def build_result
      accounts = scoped_accounts
      return empty_result(invalid_account_scope: true) if accounts.nil?

      providers = SnaptradeAccount.linked_to(accounts.pluck(:id)).to_a
      sources = providers.map do |provider|
        { provider: provider, freshness: snapshot_freshness(provider), readable: readable_options_payload?(provider) }
      end
      entries = sources.flat_map { |source| source[:readable] ? provider_rows(source[:provider]) : [] }
      rows = entries.map { |entry| build_row(**entry) }
      contexts = build_contexts(sources, rows)
      unreadable = sources.count { |source| !source[:readable] }
      Result.new(rows: rows, groups: build_groups(rows, complete: unreadable.zero?),
                 summary: build_summary(rows, complete: unreadable.zero?, unreadable_sources: unreadable), ideas: build_ideas(rows, contexts),
                 invalid_account_scope: false, source_state: source_state(sources, entries), contexts: contexts)
    end

    def scoped_accounts
      scope = @user.accessible_accounts.visible
      return scope if @account_id.blank?

      account = scope.where(id: @account_id).first
      account ? scope.where(id: account.id) : nil
    end

    def provider_rows(provider)
      account = provider.current_account
      return [] unless account

      provider.option_positions_snapshot.filter_map do |position|
        next if position.quantity.nil? || position.quantity.zero?

        { provider: provider, account: account, position: position }
      end
    end

    def build_row(provider:, account:, position:)
      parsed = standard_contract(position)
      quote = parsed && OptionQuote.lookup(underlying: parsed[:root], expiration: parsed[:expiration], option_type: parsed[:option_type],
                                           strike: parsed[:strike], multiplier: position.multiplier)
      quote = nil unless quote&.currency == position.currency
      current = snapshot_freshness(provider) == "current"
      broker_mark = nonnegative_decimal(position.mark)
      mark = Options::Mark.resolve(quote: quote, broker_mark: broker_mark, broker_snapshot_current: current, now: @now)
      quantity = decimal(position.quantity)
      multiplier = decimal(position.multiplier)
      cost_basis = nonnegative_decimal(position.cost_basis)
      day_gain = Options::DayGain.resolve(mark: mark, quote: quote, quantity: quantity, multiplier: multiplier,
                                          position_changed_today: nil, now: @now)
      model_delta = direct_quote?(quote, mark) ? Options::ModelDelta.compute(row: quote, now: @now) : Options::ModelDelta::Result.new(value: nil, iv: nil, reason: :no_direct_quote)

      Row.new(
        account_id: account.id, account_name: account.name, account_currency: account.currency, contract: position.contract,
        underlying: position.underlying, option_type: position.type, expiration: position.expiration, strike: decimal(position.strike),
        quantity: quantity, multiplier: multiplier, side: side(quantity), currency: position.currency,
        broker_mark: broker_mark, broker_snapshot_current: current, broker_synced_at: provider.last_holdings_sync,
        quote: quote, quote_as_of: quote&.quote_time, mark: mark,
        mark_value_signed: signed_mark_value(mark, quantity, multiplier), entry_basis_total: entry_basis(cost_basis, quantity, multiplier),
        total_pnl: total_pnl(mark, cost_basis, quantity, multiplier), day_gain: day_gain, model_delta: model_delta,
        position_delta: model_delta.value.nil? ? nil : Options::ModelDelta.position_delta(delta: model_delta.value, quantity: quantity, multiplier: multiplier),
        evidence_status: evidence_status(mark, provider), evidence_reason: evidence_reason(mark, provider)
      )
    end

    def standard_contract(position)
      parsed = OptionQuote.parse_occ(position.contract)
      return nil unless parsed && parsed[:root].match?(/\A[A-Z]+\z/)
      return nil unless parsed[:root] == position.underlying && parsed[:expiration] == position.expiration && parsed[:option_type] == position.type && parsed[:strike] == position.strike

      parsed
    end

    def direct_quote?(quote, mark)
      !quote.nil? && %i[mid last].include?(mark.basis)
    end

    def side(quantity)
      return :long if quantity&.positive?
      return :short if quantity&.negative?

      nil
    end

    def signed_mark_value(mark, quantity, multiplier)
      return nil unless mark.aggregatable? && valid_quantity_multiplier?(quantity, multiplier)

      mark.value * quantity * multiplier
    end

    def entry_basis(cost_basis, quantity, multiplier)
      return nil unless cost_basis && valid_quantity_multiplier?(quantity, multiplier)

      cost_basis * quantity.abs * multiplier
    end

    def total_pnl(mark, cost_basis, quantity, multiplier)
      return nil unless mark.aggregatable? && cost_basis && valid_quantity_multiplier?(quantity, multiplier)

      (mark.value - cost_basis) * quantity * multiplier
    end

    def valid_quantity_multiplier?(quantity, multiplier)
      quantity && multiplier && quantity.finite? && multiplier.finite? && !quantity.zero? && multiplier.positive?
    end

    # Same-account accounting is trusted only for standard 100-share OCC contracts whose instrument fields agree with
    # the symbol and whose currency is the account currency.
    def accounting_clean?(row)
      return false unless row.side && row.quantity&.finite? && row.multiplier == BigDecimal("100")
      return false unless row.strike&.finite? && row.strike.positive? && row.currency.present? && row.currency == row.account_currency

      parsed = OptionQuote.parse_occ(row.contract)
      !parsed.nil? && parsed[:root].match?(/\A[A-Z]+\z/) && parsed[:root] == row.underlying && parsed[:expiration] == row.expiration &&
        parsed[:option_type] == row.option_type && parsed[:strike] == row.strike
    end

    def evidence_status(mark, provider)
      return :current if mark.aggregatable? && %i[mid last].include?(mark.basis)
      return :indicative if mark.basis == :indicative
      return :broker if mark.basis == :broker
      return :stale if mark.reason == :stale_quote || snapshot_freshness(provider) == "stale"

      :unavailable
    end

    def evidence_reason(mark, provider)
      return mark.reason if mark.reason
      return :stale_snapshot if snapshot_freshness(provider) == "stale"

      nil
    end

    def build_groups(rows, complete: true)
      rows.group_by { |row| row.underlying || "—" }.transform_values do |grouped|
        currencies = grouped.map(&:currency).uniq
        pnl = aggregate(grouped.map(&:total_pnl), currencies, complete: complete)
        Group.new(underlying: grouped.first.underlying || "—", rows: grouped, total_pnl: pnl,
                  currency: single_currency(currencies), unavailable_count: grouped.count { |row| row.total_pnl.nil? || row.evidence_status == :indicative })
      end
    end

    # Totals exist only when every source was readable, every row has the one shared currency, and every row has a value.
    def build_summary(rows, complete: true, unreadable_sources: 0)
      currencies = rows.map(&:currency).uniq
      total_pnl = aggregate(rows.map(&:total_pnl), currencies, complete: complete)
      deltas = rows.map(&:position_delta)
      Summary.new(
        contract_count: rows.size, expiring_soon_count: rows.count { |row| expiring_soon?(row) }, expired_count: rows.count { |row| expired?(row) },
        current_mark_count: rows.count { |row| row.evidence_status == :current }, indicative_count: rows.count { |row| row.evidence_status == :indicative },
        unavailable_count: rows.count { |row| row.total_pnl.nil? || row.evidence_status == :indicative }, total_pnl: total_pnl,
        total_pnl_currency: total_pnl ? single_currency(currencies) : nil, day_pnl: nil,
        total_position_delta: complete && !rows.empty? && deltas.none?(&:nil?) ? deltas.sum(BigDecimal("0")) : nil,
        position_delta_exclusion_count: deltas.count(&:nil?), unreadable_source_count: unreadable_sources
      )
    end

    def aggregate(values, currencies, complete: true)
      return nil unless complete && !values.empty? && values.none?(&:nil?) && single_currency(currencies)

      values.sum(BigDecimal("0"))
    end

    def single_currency(currencies)
      currencies.first if currencies.size == 1 && currencies.first.present?
    end

    def expired?(row)
      row.expiration && row.expiration < Options::MarketCalendar.market_date(@now)
    end

    def expiring_soon?(row)
      row.expiration && !expired?(row) && (row.expiration - Options::MarketCalendar.market_date(@now)).to_i <= EXPIRING_SOON_DAYS
    end

    def build_contexts(sources, rows)
      sources.each_with_object({}) do |source, contexts|
        provider = source[:provider]
        account = provider.current_account
        next unless account

        account_rows = rows.select { |row| row.account_id == account.id }
        shares_by_underlying = current_provider_shares(provider, account)
        underlyings = (account_rows.map(&:underlying) + shares_by_underlying.keys).compact.uniq.sort
        # An unreadable option snapshot leaves existing option exposure unknown, so nothing is derived from it.
        # Any open contract whose fields cannot be tied to its OCC symbol, a standard 100 multiplier and the account
        # currency makes this account's existing exposure unknown, so shares and cash-needed figures are withheld.
        current = snapshot_freshness(provider) == "current" && source[:readable] && account_rows.all? { |row| accounting_clean?(row) }
        short_puts = account_rows.select { |row| row.side == :short && row.option_type == "PUT" }
        exposure = current && short_puts.all? { |row| valid_quantity_multiplier?(row.quantity, row.multiplier) && row.strike } ?
          short_puts.sum(BigDecimal("0")) { |row| row.strike * row.quantity.abs * row.multiplier } : nil

        underlyings.each do |underlying|
          short_call_shares = account_rows.select { |row| row.underlying == underlying && row.side == :short && row.option_type == "CALL" }
                                          .sum(BigDecimal("0")) { |row| row.quantity.abs * row.multiplier }
          raw_shares = shares_by_underlying[underlying]
          shares_available = raw_shares && current ? [ raw_shares - short_call_shares, BigDecimal("0") ].max : nil
          contexts[[ account.id, underlying ]] = Options::IdeaScanner::Context.new(
            account_id: account.id, account_name: account.name, underlying: underlying, shares_available: shares_available,
            cash_available: nil, existing_short_put_exposure: exposure, currency: account.currency, basis_per_share: nil,
            long_calls_present: current ? account_rows.any? { |row| row.underlying == underlying && row.side == :long && row.option_type == "CALL" } : nil,
            earnings_date: nil, earnings_known: false, ex_dividend_date: nil
          )
        end
      end
    end

    def current_provider_shares(provider, account)
      link = provider.account_provider
      return {} unless snapshot_freshness(provider) == "current" && link&.account_id == account.id

      holdings = Holding.joins(:security).where(account_id: account.id, account_provider_id: link.id,
                                                 securities: { kind: "standard" })
      latest_date = holdings.maximum(:date)
      return {} unless latest_date

      holdings.where(date: latest_date).group("UPPER(securities.ticker)").sum(:qty).transform_values { |quantity| decimal(quantity) }
    end

    def build_ideas(_rows, contexts)
      quote_rows = scoped_idea_quotes(contexts)
      Ideas.new(covered_calls: Options::IdeaScanner.scan(kind: :covered_call, rows: quote_rows, contexts: contexts, now: @now),
                puts: Options::IdeaScanner.scan(kind: :cash_needed_put, rows: quote_rows, contexts: contexts, now: @now))
    end

    def scoped_idea_quotes(contexts)
      currencies = contexts.values.group_by(&:underlying).transform_values { |items| items.map(&:currency).compact.uniq }
      allowed = currencies.select { |_underlying, values| values.one? }
      return [] if allowed.empty?

      OptionQuote.where(underlying: allowed.keys, currency: allowed.values.flatten.uniq,
                        session_date: Options::MarketCalendar.latest_session(@now),
                        contract_size: OptionQuote::STANDARD_CONTRACT_SIZE)
                 .order(:underlying, :contract_symbol, :id).filter_map do |quote|
        quote.attributes.symbolize_keys if allowed[quote.underlying] == [ quote.currency ]
      end.uniq { |quote| quote[:id] }
    end

    def readable_options_payload?(provider)
      payload = provider.raw_options_payload
      return false unless payload.is_a?(Array)

      payload.all? do |position|
        position = options_payload_hash(position)
        position.present? && options_payload_hash(position[:instrument]).present?
      end && accountable_option_snapshot?(provider.option_positions_snapshot, payload.size)
    rescue StandardError
      false
    end

    # Every entry must yield a position whose side, type, underlying and size are known. A zero quantity is genuine;
    # a nil quantity (or unknown type/underlying/multiplier) would be silently dropped from same-account accounting.
    def accountable_option_snapshot?(positions, payload_size)
      positions.size == payload_size && positions.all? do |position|
        position.quantity&.finite? && position.multiplier&.finite? && position.multiplier.positive? && position.underlying.present? &&
          %w[CALL PUT].include?(position.type)
      end
    end

    def options_payload_hash(value)
      hash = value.is_a?(Hash) ? value : value.to_h if value.respond_to?(:to_h) || value.is_a?(Hash)
      hash.with_indifferent_access if hash.is_a?(Hash)
    rescue StandardError
      nil
    end

    def source_state(sources, entries)
      return :unavailable if sources.empty?
      return :stale if sources.any? { |source| source[:freshness] == "stale" }
      return :unavailable if sources.any? { |source| source[:freshness] != "current" || !source[:readable] }
      return :empty if entries.empty?

      :available
    end

    def snapshot_freshness(provider)
      synced_at = provider.last_holdings_sync
      return "unavailable" if synced_at.nil?

      synced_at < @now - SnaptradeAccount::SNAPSHOT_STALE_AFTER ? "stale" : "current"
    end

    def empty_result(invalid_account_scope:)
      Result.new(rows: [], groups: {}, summary: build_summary([]), ideas: build_ideas([], {}), invalid_account_scope: invalid_account_scope,
                 source_state: :unavailable, contexts: {})
    end

    # Per-share option prices and cost bases cannot be negative; a negative payload value is corrupt, not a credit.
    def nonnegative_decimal(value)
      number = decimal(value)
      number unless number&.negative?
    end

    def decimal(value)
      return nil if value.nil?

      number = BigDecimal(value.to_s)
      number.finite? ? number : nil
    rescue ArgumentError
      nil
    end
end
