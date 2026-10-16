# frozen_string_literal: true

require "test_helper"

module Options
  module Adversarial
  end
end

# Hostile ModelDelta tests from options-spec-v2 §1.5.
class Options::Adversarial::ModelDeltaTest < ActiveSupport::TestCase
  Row = Struct.new(
    :option_type, :strike, :expiration, :bid, :ask, :underlying_price,
    :quote_time, :session_date,
    keyword_init: true
  )

  setup do
    @now = Time.utc(2026, 10, 15, 19, 59, 0)
    @session = Date.new(2026, 10, 15)
    @exp = Date.new(2026, 11, 13)
    @qt = Time.utc(2026, 10, 15, 19, 59, 0)
  end

  def row(**overrides)
    Row.new(
      option_type: "PUT",
      strike: BigDecimal("215"),
      expiration: @exp,
      bid: BigDecimal("7.05"),
      ask: BigDecimal("7.20"),
      underlying_price: BigDecimal("217.23"),
      quote_time: @qt,
      session_date: @session,
      **overrides
    )
  end

  def compute(r = row, now: @now)
    Options::ModelDelta.compute(row: r, now: now, rate: Options.risk_free_rate)
  end

  test "refuses :no_two_sided_market when bid is not > 0 or ask is not > bid" do
    assert_equal :no_two_sided_market, compute(row(bid: BigDecimal("0"), ask: BigDecimal("7.20"))).reason
    assert_nil compute(row(bid: BigDecimal("0"), ask: BigDecimal("7.20"))).value
    assert_equal :no_two_sided_market, compute(row(bid: nil, ask: BigDecimal("7.20"))).reason
    assert_equal :no_two_sided_market, compute(row(bid: BigDecimal("7.20"), ask: BigDecimal("7.20"))).reason
  end

  test "refuses :wide_spread when Mark spread tolerance is exceeded" do
    r = compute(row(bid: BigDecimal("1"), ask: BigDecimal("10")))
    assert_equal :wide_spread, r.reason
    assert_nil r.value
  end

  test "refuses :stale_quote when session_date is not latest_session(now)" do
    r = compute(row(session_date: Date.new(2026, 10, 14)))
    assert_equal :stale_quote, r.reason
    assert_nil r.value
  end

  test "refuses :too_close_to_expiry when fewer than 2 trading days remain" do
    # Thursday 2026-11-12 -> Friday 2026-11-13 expiration: trading_days_between == 1
    now = Time.utc(2026, 11, 12, 15, 0, 0) # 10:00 EST
    r = compute(
      row(
        session_date: Date.new(2026, 11, 12),
        quote_time: now,
        expiration: Date.new(2026, 11, 13)
      ),
      now: now
    )
    assert_equal :too_close_to_expiry, r.reason
    assert_nil r.value

    # expiry day: trading_days_between(from, from) == 0
    now2 = Time.utc(2026, 11, 13, 15, 0, 0)
    r2 = compute(
      row(session_date: Date.new(2026, 11, 13), quote_time: now2, expiration: Date.new(2026, 11, 13)),
      now: now2
    )
    assert_equal :too_close_to_expiry, r2.reason
  end

  test "refuses :no_underlying when underlying_price is missing" do
    r = compute(row(underlying_price: nil))
    assert_equal :no_underlying, r.reason
    assert_nil r.value
  end

  test "refuses :iv_unsolved when mid cannot be inverted or BS price misses [bid, ask]" do
    # Deep ITM put, mid far below intrinsic ~ 250-217.23 = 32.77
    r = compute(row(strike: BigDecimal("250"), bid: BigDecimal("1.00"), ask: BigDecimal("1.10")))
    assert_equal :iv_unsolved, r.reason
    assert_nil r.value
  end

  test "refuses :no_two_sided_market on a crossed book" do
    r = compute(row(bid: BigDecimal("7.50"), ask: BigDecimal("7.00")))
    assert_equal :no_two_sided_market, r.reason
    assert_nil r.value
  end

  test "healthy NVDA 2026-11-13 215P-style case: delta in (-0.5, -0.35) from sample numbers" do
    payload = JSON.parse(Rails.root.join("test/fixtures/files/yahoo-options-NVDA.json").read)
    raw = payload.fetch("optionChain").fetch("result").fetch(0).fetch("options").fetch(0).fetch("puts")
                 .find { |p| p["strike"] == 215.0 }
    refute_nil raw
    assert_equal 7.05, raw["bid"]
    assert_equal 7.2, raw["ask"]

    r = compute(
      row(
        option_type: "PUT",
        strike: BigDecimal("215"),
        expiration: Date.new(2026, 11, 13),
        bid: BigDecimal("7.05"),
        ask: BigDecimal("7.20"),
        underlying_price: BigDecimal("217.23"),
        quote_time: Time.utc(2026, 10, 15, 19, 59, 0),
        session_date: Date.new(2026, 10, 15)
      )
    )
    refute_nil r.value, r.reason.inspect
    refute_nil r.iv
    assert r.value > -0.5, "delta #{r.value} not > -0.5"
    assert r.value < -0.35, "delta #{r.value} not < -0.35"
    # Yahoo IV must not be copied in
    refute_in_delta raw["impliedVolatility"], r.iv, 1e-12 if r.iv
    # years uses close_time(expiration) - quote_time over 31_536_000
    close = Options::MarketCalendar.close_time(Date.new(2026, 11, 13))
    years = (close - Time.utc(2026, 10, 15, 19, 59, 0)) / 31_536_000.0
    px = Options::BlackScholes.price(
      type: "PUT", spot: 217.23, strike: 215.0, years: years, vol: r.iv,
      rate: Options.risk_free_rate, dividend_yield: 0
    )
    assert px >= 7.05 && px <= 7.20, "solved IV must reprice inside [bid, ask], got #{px}"
  end

  test "call/put delta relation at matched inputs: put ≈ call - 1" do
    put = compute(row(option_type: "PUT"))
    call = compute(row(option_type: "CALL", bid: BigDecimal("7.45"), ask: BigDecimal("7.65"), strike: BigDecimal("215")))
    # 215C with spot 217.23 is slightly ITM; still a two-sided tight market.
    refute_nil put.value
    refute_nil call.value
    assert put.value < 0
    assert call.value > 0
    # Same strike/spot/time: put_delta = call_delta - e^{-qT}
    matched_put = compute(row(option_type: "PUT", bid: BigDecimal("5.00"), ask: BigDecimal("5.20"), strike: BigDecimal("210")))
    matched_call = compute(row(option_type: "CALL", bid: BigDecimal("12.00"), ask: BigDecimal("12.30"), strike: BigDecimal("210")))
    if matched_put.value && matched_call.value
      assert_in_delta matched_call.value - 1.0, matched_put.value, 0.05
    end
  end

  test "position_delta sign table" do
    short_put = Options::ModelDelta.position_delta(delta: -0.425, quantity: -1, multiplier: 100)
    assert_equal BigDecimal("42.5"), short_put
    short_call = Options::ModelDelta.position_delta(delta: 0.30, quantity: -1, multiplier: 100)
    assert_equal BigDecimal("-30"), short_call
    long_call = Options::ModelDelta.position_delta(delta: 0.30, quantity: 2, multiplier: 100)
    assert_equal BigDecimal("60"), long_call
    long_put = Options::ModelDelta.position_delta(delta: -0.425, quantity: 1, multiplier: 100)
    assert_equal BigDecimal("-42.5"), long_put
    assert_nil Options::ModelDelta.position_delta(delta: -0.425, quantity: 0, multiplier: 100)
    assert_nil Options::ModelDelta.position_delta(delta: nil, quantity: -1, multiplier: 100)
    assert_nil Options::ModelDelta.position_delta(delta: -0.425, quantity: nil, multiplier: 100)
    assert_nil Options::ModelDelta.position_delta(delta: -0.425, quantity: -1, multiplier: nil)
  end

  test "Result exposes value, iv, reason" do
    r = compute
    %i[value iv reason].each { |f| assert_respond_to r, f }
  end
end
