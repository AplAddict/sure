# Model delta from OUR implied vol (solved from the quote mid), never Yahoo's impliedVolatility.
# Refuses (nil + reason) whenever the inputs cannot support a trustworthy number; refusing beats guessing.
module Options::ModelDelta
  SECONDS_PER_YEAR = 31_536_000.0
  MIN_TRADING_DAYS_TO_EXPIRY = 2
  PRICE_SLACK = 1e-6 # solver tolerance on price

  Result = Data.define(:value, :iv, :reason)

  module_function

  # row duck: option_type, strike, expiration (Date), bid, ask, underlying_price, quote_time, session_date
  # reasons: :no_two_sided_market :wide_spread :stale_quote :too_close_to_expiry :no_underlying :iv_unsolved
  def compute(row:, now:, rate: Options.risk_free_rate)
    read = ->(key) { Options::Values.read(row, key) }
    bid = Options::Values.decimal(read.call(:bid))
    ask = Options::Values.decimal(read.call(:ask))
    return refuse(:no_two_sided_market) unless bid&.positive? && ask && ask > bid
    return refuse(:wide_spread) unless Options::Mark.tight_spread?(bid, ask)

    quote_time = Options::Values.time(read.call(:quote_time), Options::MarketCalendar::ZONE_NAME)
    return refuse(:stale_quote) if quote_time.nil? || read.call(:session_date) != Options::MarketCalendar.latest_session(now)

    expiration = read.call(:expiration)
    expiration = expiration.to_date if expiration.respond_to?(:to_date)
    days = expiration.is_a?(Date) ? Options::MarketCalendar.trading_days_between(Options::MarketCalendar.market_date(now), expiration) : 0
    return refuse(:too_close_to_expiry) if days < MIN_TRADING_DAYS_TO_EXPIRY

    spot = Options::Values.decimal(read.call(:underlying_price))
    return refuse(:no_underlying) unless spot&.positive?

    solve(read.call(:option_type), spot, Options::Values.decimal(read.call(:strike)), expiration, quote_time, bid, ask, rate)
  end

  # shares-equivalent exposure = delta * quantity * multiplier (short put -0.425 x -1 x 100 = +42.5).
  def position_delta(delta:, quantity:, multiplier:)
    delta = Options::Values.decimal(delta)
    quantity = Options::Values.decimal(quantity)
    multiplier = Options::Values.decimal(multiplier)
    return nil if delta.nil? || quantity.nil? || multiplier.nil? || quantity.zero?

    delta * quantity * multiplier
  end

  def solve(type, spot, strike, expiration, quote_time, bid, ask, rate)
    years = (Options::MarketCalendar.close_time(expiration) - quote_time) / SECONDS_PER_YEAR
    args = { type: type, spot: spot, strike: strike, years: years, rate: rate }
    iv = Options::BlackScholes.implied_vol(price: (bid + ask) / 2, **args)
    return refuse(:iv_unsolved) if iv.nil?

    model_price = Options::BlackScholes.price(vol: iv, **args)
    return refuse(:iv_unsolved) if model_price.nil? || model_price < bid.to_f - PRICE_SLACK || model_price > ask.to_f + PRICE_SLACK

    delta = Options::BlackScholes.delta(vol: iv, **args)
    return refuse(:iv_unsolved) if delta.nil?

    Result.new(value: delta, iv: iv, reason: nil)
  end

  def refuse(reason)
    Result.new(value: nil, iv: nil, reason: reason)
  end
  private_class_method :solve, :refuse
end
