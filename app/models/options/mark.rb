# Chooses the mark to display for an option contract and says what it is based on.
# Basis order: a current two-sided market (:mid, or :indicative when the spread is wide), the current
# session's last print (:last), then a current broker snapshot mark (:broker). Anything else is nil with a reason.
# nil means unknown; 0 is a real zero price and is kept.
module Options::Mark
  AGGREGATABLE_BASES = %i[mid last broker].freeze
  MAX_SPREAD_FRACTION = BigDecimal("0.25")
  MIN_SPREAD_ALLOWANCE = BigDecimal("0.10")

  # stale: a quote existed but belonged to an earlier session. as_of is the quote's own quote_time
  # (never a fetch time); it is nil for :broker. bid/ask are set only when the value came from the market quote.
  Result = Data.define(:value, :basis, :source, :as_of, :stale, :reason, :bid, :ask) do
    def aggregatable?
      Options::Mark::AGGREGATABLE_BASES.include?(basis)
    end
  end

  module_function

  def resolve(quote:, broker_mark:, broker_snapshot_current:, now:)
    session = Options::MarketCalendar.latest_session(now)
    current = !quote.nil? && Options::Values.read(quote, :session_date) == session
    broker = Options::Values.decimal(broker_mark)

    if current
      market = market_value(
        bid: Options::Values.decimal(Options::Values.read(quote, :bid)),
        ask: Options::Values.decimal(Options::Values.read(quote, :ask)),
        last_price: Options::Values.decimal(Options::Values.read(quote, :last_price)),
        last_trade_at: Options::Values.read(quote, :last_trade_at),
        session: session
      )
      return quote_result(quote, market) if market
    end

    if broker && broker_snapshot_current == true
      return Result.new(value: broker, basis: :broker, source: :broker_snapshot, as_of: nil,
                        stale: !quote.nil? && !current, reason: nil, bid: nil, ask: nil)
    end

    reason = if quote.nil? then :no_mark elsif current then :no_market else :stale_quote end
    Result.new(value: nil, basis: nil, source: nil, as_of: nil, stale: !quote.nil? && !current,
               reason: reason, bid: nil, ask: nil)
  end

  # Rules 2-3 only, judged against the row's own session. Used to roll prev_session_mark forward.
  def session_mark(bid:, ask:, last_price:, last_trade_at:, session_date:)
    return nil if session_date.nil?

    market = market_value(
      bid: Options::Values.decimal(bid), ask: Options::Values.decimal(ask),
      last_price: Options::Values.decimal(last_price), last_trade_at: last_trade_at, session: session_date.to_date
    )
    market && market[:basis] != :indicative ? market[:value] : nil
  end

  # (ask - bid) / mid <= max(0.25, 0.10 / mid), i.e. spread <= max(25% of mid, 10 cents). Needs bid > 0, ask > bid.
  def tight_spread?(bid, ask)
    mid = (bid + ask) / 2
    (ask - bid) <= [ mid * MAX_SPREAD_FRACTION, MIN_SPREAD_ALLOWANCE ].max
  end

  def quote_result(quote, market)
    Result.new(
      value: market[:value], basis: market[:basis], source: :market_quote,
      as_of: Options::Values.time(Options::Values.read(quote, :quote_time), Options::MarketCalendar::ZONE_NAME),
      stale: false, reason: nil, bid: market[:bid], ask: market[:ask]
    )
  end

  def market_value(bid:, ask:, last_price:, last_trade_at:, session:)
    if bid && ask && bid.positive? && ask > bid
      return { value: (bid + ask) / 2, basis: tight_spread?(bid, ask) ? :mid : :indicative, bid: bid, ask: ask }
    end

    return nil unless last_price && last_price >= 0 && Options::Values.market_date_of(last_trade_at) == session
    return nil if bid && ask && ask >= bid && !(bid <= last_price && last_price <= ask)

    { value: last_price, basis: :last, bid: bid, ask: ask }
  end

  private_class_method :quote_result, :market_value
end
