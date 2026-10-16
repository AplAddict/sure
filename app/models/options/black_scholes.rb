# European Black-Scholes-Merton with continuous dividend yield. Float math lives only here;
# callers convert at the boundary. American early-exercise premium and discrete dividends are ignored.
# Returns nil (never raises, never NaN) whenever an input is missing, non-finite or unreliable.
module Options::BlackScholes
  MIN_VOL_EXCLUSIVE = 0.01
  MAX_VOL = 5.0
  TYPES = %w[CALL PUT].freeze
  PRICE_TOLERANCE = 1e-6
  IV_ITERATIONS = 200

  module_function

  def delta(type:, spot:, strike:, years:, vol:, rate: Options.risk_free_rate, dividend_yield: 0)
    inputs = prepare(type, spot, strike, years, vol, rate, dividend_yield) or return nil
    d1 = d1_for(inputs)
    discount = Math.exp(-inputs[:q] * inputs[:t])

    value = inputs[:type] == "CALL" ? discount * cdf(d1) : -discount * cdf(-d1)
    clamp(value, inputs[:type])
  end

  def price(type:, spot:, strike:, years:, vol:, rate: Options.risk_free_rate, dividend_yield: 0)
    inputs = prepare(type, spot, strike, years, vol, rate, dividend_yield) or return nil
    d1 = d1_for(inputs)
    d2 = d1 - inputs[:vol] * Math.sqrt(inputs[:t])
    s_disc = inputs[:spot] * Math.exp(-inputs[:q] * inputs[:t])
    k_disc = inputs[:strike] * Math.exp(-inputs[:r] * inputs[:t])

    value = inputs[:type] == "CALL" ? s_disc * cdf(d1) - k_disc * cdf(d2) : k_disc * cdf(-d2) - s_disc * cdf(-d1)
    value.finite? ? [ value, 0.0 ].max : nil
  end

  # Solves vol by bisection on price (price is monotone increasing in vol). nil when no vol in
  # (0.01, 5.0] reproduces the price within PRICE_TOLERANCE: below discounted intrinsic, above the
  # vol = 5.0 price, below the vol = 0.01 price, a non-positive price, or any invalid input.
  def implied_vol(type:, spot:, strike:, years:, price:, rate: Options.risk_free_rate, dividend_yield: 0)
    target = to_finite_float(price)
    return nil if target.nil? || target <= 0

    lo = MIN_VOL_EXCLUSIVE + 1e-7
    hi = MAX_VOL
    args = { type: type, spot: spot, strike: strike, years: years, rate: rate, dividend_yield: dividend_yield }
    price_lo = price(vol: lo, **args) or return nil
    price_hi = price(vol: hi, **args) or return nil
    intrinsic = discounted_intrinsic(type, args) or return nil

    return nil if target < intrinsic - 1e-9
    return nil if target < price_lo - PRICE_TOLERANCE || target > price_hi + PRICE_TOLERANCE
    return lo if (target - price_lo).abs <= PRICE_TOLERANCE
    return hi if (target - price_hi).abs <= PRICE_TOLERANCE

    IV_ITERATIONS.times do
      mid = (lo + hi) / 2.0
      diff = price(vol: mid, **args) - target
      return mid if diff.abs <= PRICE_TOLERANCE / 10.0

      diff.positive? ? hi = mid : lo = mid
    end
    (lo + hi) / 2.0
  end

  def discounted_intrinsic(type, args)
    type = type.to_s.upcase
    spot = to_finite_float(args[:spot])
    strike = to_finite_float(args[:strike])
    rate = to_finite_float(args[:rate])
    div = to_finite_float(args[:dividend_yield])
    years = to_finite_float(args[:years])
    return nil if [ spot, strike, rate, div, years ].any?(&:nil?)

    s_disc = spot * Math.exp(-div * years)
    k_disc = strike * Math.exp(-rate * years)
    type == "CALL" ? [ s_disc - k_disc, 0.0 ].max : [ k_disc - s_disc, 0.0 ].max
  end

  def prepare(type, spot, strike, years, vol, rate, dividend_yield)
    type = type.to_s.upcase
    return nil unless TYPES.include?(type)

    spot, strike, years, vol = [ spot, strike, years, vol ].map { |v| to_finite_float(v) }
    r = to_finite_float(rate)
    q = to_finite_float(dividend_yield)
    return nil if [ spot, strike, years, vol, r, q ].any?(&:nil?)
    return nil unless spot > 0 && strike > 0 && years > 0
    return nil unless vol > MIN_VOL_EXCLUSIVE && vol <= MAX_VOL

    { type: type, spot: spot, strike: strike, t: years, vol: vol, r: r, q: q }
  end

  def to_finite_float(value)
    return nil unless value.is_a?(Numeric) && !value.is_a?(Complex)

    float = value.to_f
    float.finite? ? float : nil
  rescue FloatDomainError, ZeroDivisionError
    nil
  end

  def d1_for(i)
    (Math.log(i[:spot] / i[:strike]) + (i[:r] - i[:q] + i[:vol]**2 / 2.0) * i[:t]) / (i[:vol] * Math.sqrt(i[:t]))
  end

  def cdf(x)
    0.5 * Math.erfc(-x / Math.sqrt(2.0))
  end

  def clamp(value, type)
    return nil unless value.finite?

    type == "CALL" ? value.clamp(0.0, 1.0) : value.clamp(-1.0, 0.0)
  end
  private_class_method :discounted_intrinsic, :prepare, :to_finite_float, :d1_for, :cdf, :clamp
end
