# Read-only calendar projection built from the signed-in user's accessible
# holdings and verified provider snapshots. It never imports an external
# calendar and never mutates holdings, tax lots, entries, or reports.
class MarketCalendar::EventBuilder
  Event = Data.define(:event_type, :ticker, :title, :date, :end_date, :details, :source, :freshness) do
    def key = [ event_type, ticker, date, title ].join("\u0000")
  end

  def initialize(accounts:, now: Time.current)
    @accounts = accounts.to_a
    @now = now
  end

  def events
    @events ||= (fundamental_events + option_expirations + calculated_wash_sale_events).compact.uniq(&:key).sort_by { |event| [ event.date, event.ticker, event.event_type ] }
  end

  # Calculated candidates use the recorded sale, its available cost basis, and
  # same-security purchases inside the statutory +/-30-day window. They are
  # intentionally labelled calculated, because a broker's authoritative tax-lot
  # adjustment can differ when its lot method or off-platform activity differs.
  def wash_sale_status
    candidates = events.count { |event| event.event_type == "wash_sale" }
    if candidates.positive?
      { available: true, reason: "#{candidates} wash-sale watch #{'window'.pluralize(candidates)} derived from recorded loss sales. Each window runs for 30 days after its sale date and flags recorded replacement purchases." }
    else
      { available: false, reason: "No calculated wash-sale candidates were found in accessible recorded trade history. Broker-confirmed tax adjustments remain the authority." }
    end
  end

  private
    def fundamental_events
      held_securities.filter_map do |security|
        fundamental = security.fundamental
        next unless fundamental&.available?

        [
          event_for_date("earnings", security, fundamental.next_earnings_date, "Earnings", fundamental),
          event_for_date("ex_dividend", security, fundamental.ex_dividend_date, "Ex-dividend date", fundamental)
        ]
      end.flatten
    end

    def event_for_date(type, security, value, label, fundamental)
      date = parse_date(value)
      return unless date

      Event.new(
        event_type: type,
        ticker: security.ticker,
        title: "#{security.ticker} — #{label}",
        date: date,
        end_date: date,
        details: security.name.presence || security.ticker,
        source: "Cached market data",
        freshness: fundamental.stale? ? "stale" : "current"
      )
    end

    def calculated_wash_sale_events
      trades = accessible_trades
      trades.select { |trade| loss_sale?(trade) }.filter_map do |sale|
        window_end = sale.entry.date + 30.days
        replacements = trades.select do |purchase|
          purchase.buy? && purchase.security_id == sale.security_id && purchase.entry.date.between?(sale.entry.date, window_end)
        end
        replacement_quantity = replacements.sum { |purchase| purchase.qty.to_d.abs }
        replacement_detail = if replacement_quantity.positive?
          " #{replacement_quantity.to_s('F')} replacement shares are recorded inside the window."
        else
          " No replacement purchases are currently recorded inside the window."
        end

        Event.new(
          event_type: "wash_sale",
          ticker: sale.security.ticker,
          title: "#{sale.security.ticker} — Wash-sale watch window",
          date: sale.entry.date,
          end_date: window_end,
          details: "30-day post-loss-sale window from recorded trade.#{replacement_detail}",
          source: "Recorded trades & retained cost basis",
          freshness: "calculated"
        )
      end
    end

    def accessible_trades
      Trade.joins(:entry)
           .where(entries: { account_id: @accounts.map(&:id) })
           .includes(:entry, :security)
           .to_a
    end

    def loss_sale?(trade)
      return false unless trade.sell? && !trade.internal_movement?

      realized = trade.realized_gain_loss
      realized.present? && realized.value.negative?
    end

    def option_expirations
      account_ids = @accounts.map(&:id).to_set
      SnaptradeAccount.includes(:account_provider).filter_map do |provider_account|
        account = provider_account.current_account
        next unless account && account_ids.include?(account.id)

        Array(provider_account.raw_options_payload).filter_map do |raw_position|
          position = raw_position.to_h.with_indifferent_access
          instrument = position[:instrument].to_h.with_indifferent_access
          contract = instrument[:symbol].to_s
          match = contract.match(/\A([A-Z.]+)\s+.*?(\d{6})([CP])\d+\z/)
          next unless match
          expiration = Date.strptime(match[2], "%y%m%d") rescue nil
          next unless expiration

          Event.new(
            event_type: "options_expiration",
            ticker: match[1],
            title: "#{match[1]} — Options expiration",
            date: expiration,
            end_date: expiration,
            details: contract,
            source: "Read-only brokerage options snapshot",
            freshness: provider_account.last_holdings_sync && provider_account.last_holdings_sync < 30.hours.ago ? "stale" : "current"
          )
        end
      end.flatten
    end

    def held_securities
      @held_securities ||= @accounts.flat_map do |account|
        holdings = account.current_holdings
        holdings = holdings.includes(security: :fundamental) if holdings.respond_to?(:includes)
        holdings.map(&:security)
      end.compact.uniq(&:id)
    end

    def parse_date(value)
      return value if value.is_a?(Date)
      Date.parse(value.to_s)
    rescue ArgumentError
      nil
    end
end
