# Day gain/loss for an option position. Signed quantity makes shorts invert automatically.
# nil in => nil out; a zero result is a real zero. Money is BigDecimal.
#
# resolve prefers (mark - previous session mark), which is internally consistent with the mark we show.
# Yahoo's `change` is only a fallback, and only when it passes sanity checks: the real NVDA chain
# carries per-contract changes far larger than the underlying's own move, which must never become a gain.
module Options::DayGain
  CHANGE_SLACK = BigDecimal("0.05")

  # basis: :session_mark | :yahoo_change | nil. reason is set whenever value is nil:
  # :position_changed_today, :position_unknown, :no_mark, :no_quantity, :no_multiplier, :unreliable_reference.
  Result = Data.define(:value, :basis, :reason)

  module_function

  def per_contract(change:, quantity:, multiplier:)
    change = Options::Values.decimal(change)
    quantity = Options::Values.decimal(quantity)
    multiplier = Options::Values.decimal(multiplier)
    return nil if change.nil? || quantity.nil? || multiplier.nil? || quantity.zero?

    change * quantity * multiplier
  end

  def resolve(mark:, quote:, quantity:, multiplier:, position_changed_today:, now:)
    return unavailable(:position_changed_today) if position_changed_today == true
    return unavailable(:position_unknown) unless position_changed_today == false

    mark_value = aggregatable_value(mark)
    return unavailable(:no_mark) if mark_value.nil?

    quantity = Options::Values.decimal(quantity)
    return unavailable(:no_quantity) if quantity.nil? || quantity.zero?

    multiplier = Options::Values.decimal(multiplier)
    return unavailable(:no_multiplier) if multiplier.nil? || !multiplier.positive?

    session = Options::MarketCalendar.latest_session(now)
    previous_mark = Options::Values.decimal(Options::Values.read(quote, :prev_session_mark))
    previous_date = Options::Values.read(quote, :prev_session_date)
    if previous_mark && previous_date && Options::MarketCalendar.trading_days_between(previous_date, session) == 1
      return Result.new(value: (mark_value - previous_mark) * quantity * multiplier, basis: :session_mark, reason: nil)
    end

    change = reliable_change(quote, session)
    return unavailable(:unreliable_reference) if change.nil?

    Result.new(value: change * quantity * multiplier, basis: :yahoo_change, reason: nil)
  end

  def aggregatable_value(mark)
    return nil unless mark.respond_to?(:aggregatable?) && mark.aggregatable?

    Options::Values.decimal(mark.value)
  end

  def unavailable(reason)
    Result.new(value: nil, basis: nil, reason: reason)
  end

  # Yahoo's change, or nil when any reliability check fails (see v2 1.4).
  def reliable_change(quote, session)
    return nil if quote.nil?

    read = ->(key) { Options::Values.read(quote, key) }
    bid, ask, last, change = %i[bid ask last_price change].map { |k| Options::Values.decimal(read.call(k)) }
    underlying, prev_close, strike = %i[underlying_price underlying_prev_close strike].map { |k| Options::Values.decimal(read.call(k)) }
    type = read.call(:option_type).to_s.upcase
    return nil if [ bid, ask, last, change, underlying, prev_close, strike ].any?(&:nil?) || !%w[CALL PUT].include?(type)
    return nil unless read.call(:session_date) == session
    return nil unless bid.positive? && ask > bid
    return nil unless Options::Values.market_date_of(read.call(:last_trade_at)) == session
    return nil if change.abs > (underlying - prev_close).abs + CHANGE_SLACK
    return nil if (last - change) < intrinsic(type, strike, prev_close) - CHANGE_SLACK

    change
  end

  def intrinsic(type, strike, spot)
    value = type == "CALL" ? spot - strike : strike - spot
    value.positive? ? value : BigDecimal("0")
  end
  private_class_method :aggregatable_value, :unavailable, :reliable_change, :intrinsic
end
