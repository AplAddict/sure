require "test_helper"

class Options::ModelDeltaTest < ActiveSupport::TestCase
  MD = Options::ModelDelta
  NY = ActiveSupport::TimeZone["America/New_York"]
  Row = Struct.new(:option_type, :strike, :expiration, :bid, :ask, :underlying_price, :quote_time, :session_date, keyword_init: true)

  setup do
    @now = NY.local(2026, 10, 15, 16, 20) # Thursday, 20 minutes after the close
    @quote_time = NY.local(2026, 10, 15, 16, 0)
    @session = Date.new(2026, 10, 15)
    @expiration = Date.new(2026, 11, 13)
  end

  # NVDA 2026-11-13 215 put from the real Yahoo sample: bid 7.05 ask 7.20, underlying 217.23.
  def row(overrides = {})
    Row.new(**{
      option_type: "PUT", strike: BigDecimal("215"), expiration: @expiration, bid: BigDecimal("7.05"), ask: BigDecimal("7.20"),
      underlying_price: BigDecimal("217.23"), quote_time: @quote_time, session_date: @session
    }.merge(overrides))
  end

  def compute(r = row, now: @now, **extra)
    MD.compute(row: r, now: now, **extra)
  end

  def years_between(quote_time, expiration)
    (Options::MarketCalendar.close_time(expiration) - quote_time) / 31_536_000.0
  end

  # ---- happy path --------------------------------------------------------------------

  test "Result members" do
    assert_equal %i[value iv reason], MD::Result.members
  end

  test "put row solves our own iv from the mid and returns a negative delta" do
    result = compute
    assert_nil result.reason
    assert_kind_of Float, result.value
    assert_kind_of Float, result.iv
    assert_includes(-1.0..0.0, result.value)
    assert_in_delta(-0.43, result.value, 0.05)
    assert_in_delta 0.33, result.iv, 0.06
  end

  test "call row returns a positive delta" do
    result = compute(row(option_type: "CALL", strike: BigDecimal("215"), bid: BigDecimal("10.0"), ask: BigDecimal("10.3")))
    assert_nil result.reason
    assert_includes 0.0..1.0, result.value
    assert_in_delta 0.58, result.value, 0.06
  end

  test "option type is case insensitive" do
    assert_equal compute.value, compute(row(option_type: "put")).value
    assert_equal compute.value, compute(row(option_type: :PUT)).value
  end

  test "solved iv reprices the contract inside the quoted market" do
    result = compute
    price = Options::BlackScholes.price(type: "PUT", spot: 217.23, strike: 215, years: years_between(@quote_time, @expiration), vol: result.iv)
    assert_operator price, :>=, 7.05 - 1e-6
    assert_operator price, :<=, 7.20 + 1e-6
    assert_in_delta 7.125, price, 1e-5
  end

  test "years run from quote_time to the 16:00 ET close of the expiration date" do
    result = compute
    expected = Options::BlackScholes.delta(type: "PUT", spot: 217.23, strike: 215, years: years_between(@quote_time, @expiration), vol: result.iv)
    assert_in_delta expected, result.value, 1e-9
  end

  test "years follow wall clock close across the november dst change" do
    quote_time = NY.local(2026, 10, 30, 16, 0) # EDT
    expiration = Date.new(2026, 11, 6)        # EST close is 21:00 UTC
    now = NY.local(2026, 10, 30, 16, 20)
    r = row(quote_time: quote_time, session_date: Date.new(2026, 10, 30), expiration: expiration, strike: BigDecimal("215"))
    result = compute(r, now: now)
    expected_years = (Time.utc(2026, 11, 6, 21, 0, 0) - Time.utc(2026, 10, 30, 20, 0, 0)) / 31_536_000.0
    assert_in_delta expected_years, years_between(quote_time, expiration), 1e-12
    assert_in_delta Options::BlackScholes.delta(type: "PUT", spot: 217.23, strike: 215, years: expected_years, vol: result.iv), result.value, 1e-9
  end

  test "yahoo implied volatility on the row is never used" do
    base = compute
    with_garbage = compute({ option_type: "PUT", strike: 215, expiration: @expiration, bid: 7.05, ask: 7.20, underlying_price: 217.23,
                             quote_time: @quote_time, session_date: @session, implied_volatility: 0.01, iv: 9.0 })
    assert_equal base.value, with_garbage.value
    assert_equal base.iv, with_garbage.iv
  end

  test "the last print on the row is not used either" do
    hash = { option_type: "PUT", strike: 215, expiration: @expiration, bid: 7.05, ask: 7.20, underlying_price: 217.23,
             quote_time: @quote_time, session_date: @session, last_price: 99.0 }
    assert_equal compute.value, compute(hash).value
  end

  test "rate argument is honoured and defaults to Options.risk_free_rate" do
    assert_equal compute.value, compute(rate: Options.risk_free_rate).value
    refute_equal compute.value, compute(rate: 0.15).value
  end

  test "deterministic" do
    assert_equal compute, compute
  end

  test "float and string row values are accepted" do
    hash = { option_type: "PUT", strike: "215", expiration: @expiration, bid: 7.05, ask: "7.20", underlying_price: 217.23,
             quote_time: @quote_time, session_date: @session }
    assert_in_delta compute.value, compute(hash).value, 1e-9
  end

  # ---- refusals ----------------------------------------------------------------------

  def assert_refused(result, reason)
    assert_nil result.value, "value should be nil for #{reason}"
    assert_nil result.iv, "iv should be nil for #{reason}"
    assert_equal reason, result.reason
  end

  test "no two sided market" do
    [ { bid: nil }, { ask: nil }, { bid: BigDecimal("0") }, { bid: nil, ask: nil }, { bid: BigDecimal("-1") },
      { bid: BigDecimal("7.2"), ask: BigDecimal("7.2") }, { bid: BigDecimal("7.5"), ask: BigDecimal("7.2") },
      { bid: BigDecimal("0"), ask: BigDecimal("0") } ].each do |o|
      assert_refused compute(row(o)), :no_two_sided_market
    end
  end

  test "wide spread" do
    assert_refused compute(row(bid: BigDecimal("5"), ask: BigDecimal("9"))), :wide_spread
  end

  test "spread tolerance matches the mark rule" do
    assert_nil compute(row(bid: BigDecimal("6.40"), ask: BigDecimal("8.00"))).reason  # 1.6 / 7.2 = 22 percent
    assert_equal :wide_spread, compute(row(bid: BigDecimal("6.00"), ask: BigDecimal("8.00"))).reason # 28.6 percent
  end

  test "stale quote when the session is not the latest session" do
    assert_refused compute(row(session_date: @session - 1)), :stale_quote
    assert_refused compute(row(session_date: nil)), :stale_quote
    assert_refused compute(row(quote_time: nil)), :stale_quote
  end

  test "friday settle viewed on monday before the open is still current" do
    friday = Date.new(2026, 10, 16)
    r = row(session_date: friday, quote_time: NY.local(2026, 10, 16, 16, 0))
    assert_nil compute(r, now: NY.local(2026, 10, 19, 7, 0)).reason
    assert_equal :stale_quote, compute(r, now: NY.local(2026, 10, 19, 9, 30)).reason
  end

  test "expiring contracts are refused when fewer than two trading days remain" do
    {
      Date.new(2026, 10, 15) => 0, Date.new(2026, 10, 14) => 0, Date.new(2026, 10, 16) => 1
    }.each do |expiration, _days|
      assert_refused compute(row(expiration: expiration)), :too_close_to_expiry
    end
    assert_nil compute(row(expiration: Date.new(2026, 10, 19))).reason, "Thursday -> Monday is two trading days"
  end

  test "one day out refuses delta over a weekend and across holidays" do
    friday_now = NY.local(2026, 10, 16, 16, 20)
    friday = row(session_date: Date.new(2026, 10, 16), quote_time: NY.local(2026, 10, 16, 16, 0))
    assert_refused compute(friday.tap { |r| r.expiration = Date.new(2026, 10, 19) }, now: friday_now), :too_close_to_expiry
    assert_nil compute(friday.tap { |r| r.expiration = Date.new(2026, 10, 20) }, now: friday_now).reason

    # Wednesday before Thanksgiving: Friday is only one trading day away, Monday is two
    wed_now = NY.local(2026, 11, 25, 16, 20)
    wed = row(session_date: Date.new(2026, 11, 25), quote_time: NY.local(2026, 11, 25, 16, 0), underlying_price: BigDecimal("215"))
    wed.expiration = Date.new(2026, 11, 27)
    assert_refused compute(wed, now: wed_now), :too_close_to_expiry
    wed.expiration = Date.new(2026, 11, 30)
    assert_nil compute(wed, now: wed_now).reason
  end

  test "saturday viewing counts trading days from the new york market date" do
    sat_now = NY.local(2026, 10, 17, 12, 0)
    r = row(session_date: Date.new(2026, 10, 16), quote_time: NY.local(2026, 10, 16, 16, 0))
    r.expiration = Date.new(2026, 10, 19)
    assert_refused compute(r, now: sat_now), :too_close_to_expiry
    r.expiration = Date.new(2026, 10, 20)
    assert_nil compute(r, now: sat_now).reason
  end

  test "friday evening new york after the utc flip uses the new york date for dte" do
    late = NY.local(2026, 10, 16, 22, 0)
    assert_equal Date.new(2026, 10, 17), late.utc.to_date
    r = row(session_date: Date.new(2026, 10, 16), quote_time: NY.local(2026, 10, 16, 16, 0), expiration: Date.new(2026, 10, 19))
    assert_refused compute(r, now: late.utc), :too_close_to_expiry
  end

  test "no underlying" do
    [ nil, BigDecimal("0"), BigDecimal("-3") ].each { |v| assert_refused compute(row(underlying_price: v)), :no_underlying }
  end

  test "iv unsolved when the mid is below discounted intrinsic" do
    r = row(option_type: "CALL", strike: BigDecimal("100"), bid: BigDecimal("100.0"), ask: BigDecimal("100.2"))
    assert_refused compute(r), :iv_unsolved
  end

  test "iv unsolved when the mid is above the vol 5.0 price" do
    assert_refused compute(row(bid: BigDecimal("149.9"), ask: BigDecimal("150.1"))), :iv_unsolved
  end

  test "iv unsolved for invalid strike or option type" do
    assert_refused compute(row(strike: nil)), :iv_unsolved
    assert_refused compute(row(strike: BigDecimal("0"))), :iv_unsolved
    assert_refused compute(row(option_type: "STRADDLE")), :iv_unsolved
  end

  test "iv unsolved when the expiration is missing" do
    assert_refused compute(row(expiration: nil)), :too_close_to_expiry
  end

  test "a deep out of the money put gets a tiny negative delta rather than nil" do
    r = row(strike: BigDecimal("215"), expiration: Date.new(2026, 10, 19), underlying_price: BigDecimal("500"),
            bid: BigDecimal("0.05"), ask: BigDecimal("0.06"))
    result = compute(r)
    # deep OTM put with a cheap quote: an IV is solved and the delta is tiny but not nil
    assert_nil result.reason
    assert_operator result.value, :>, -0.01
    assert_operator result.value, :<=, 0.0
  end

  test "refusal precedence follows the contract order" do
    assert_equal :no_two_sided_market, compute(row(bid: nil, session_date: nil, underlying_price: nil, expiration: Date.new(2026, 10, 15))).reason
    assert_equal :wide_spread, compute(row(bid: BigDecimal("1"), ask: BigDecimal("9"), session_date: nil)).reason
    assert_equal :stale_quote, compute(row(session_date: nil, underlying_price: nil, expiration: Date.new(2026, 10, 15))).reason
    assert_equal :too_close_to_expiry, compute(row(underlying_price: nil, expiration: Date.new(2026, 10, 15))).reason
    assert_equal :no_underlying, compute(row(underlying_price: nil, strike: nil)).reason
  end

  # ---- host timezone -----------------------------------------------------------------

  test "result is identical under a chicago host TZ" do
    base = compute
    original = ENV["TZ"]
    ENV["TZ"] = "America/Chicago"
    begin
      assert_equal "CDT", Time.local(2026, 10, 15, 12).zone, "precondition"
      chicago_now = Time.local(2026, 10, 15, 15, 20) # 16:20 ET
      assert_equal @now.utc, chicago_now.utc
      assert_equal base, compute(now: chicago_now)
      late_friday = Time.local(2026, 10, 16, 23, 0) # Saturday 00:00 in New York
      r = row(session_date: Date.new(2026, 10, 16), quote_time: NY.local(2026, 10, 16, 16, 0), expiration: Date.new(2026, 10, 19))
      assert_refused compute(r, now: late_friday), :too_close_to_expiry
    ensure
      original.nil? ? ENV.delete("TZ") : ENV["TZ"] = original
    end
  end

  # ---- position_delta ----------------------------------------------------------------

  test "position_delta sign matrix" do
    assert_equal BigDecimal("42.5"), MD.position_delta(delta: -0.425, quantity: -1, multiplier: 100)  # short put
    assert_equal BigDecimal("-30"), MD.position_delta(delta: 0.30, quantity: -1, multiplier: 100)     # short call
    assert_equal BigDecimal("30"), MD.position_delta(delta: 0.30, quantity: 1, multiplier: 100)       # long call
    assert_equal BigDecimal("-42.5"), MD.position_delta(delta: -0.425, quantity: 1, multiplier: 100)  # long put
  end

  test "position_delta scales with quantity and multiplier and returns BigDecimal" do
    value = MD.position_delta(delta: 0.1, quantity: -3, multiplier: 100)
    assert_kind_of BigDecimal, value
    assert_equal BigDecimal("-30"), value
    assert_equal BigDecimal("-3"), MD.position_delta(delta: 0.1, quantity: -3, multiplier: 10)
    assert_equal BigDecimal("2.5"), MD.position_delta(delta: 0.1, quantity: BigDecimal("0.25"), multiplier: 100)
    assert_equal BigDecimal("12.5"), MD.position_delta(delta: BigDecimal("0.5"), quantity: "0.25", multiplier: BigDecimal("100"))
  end

  test "position_delta is nil when anything is nil or the quantity is zero" do
    assert_nil MD.position_delta(delta: nil, quantity: 1, multiplier: 100)
    assert_nil MD.position_delta(delta: 0.3, quantity: nil, multiplier: 100)
    assert_nil MD.position_delta(delta: 0.3, quantity: 1, multiplier: nil)
    assert_nil MD.position_delta(delta: 0.3, quantity: 0, multiplier: 100)
    assert_nil MD.position_delta(delta: 0.3, quantity: BigDecimal("0"), multiplier: 100)
    assert_nil MD.position_delta(delta: Float::NAN, quantity: 1, multiplier: 100)
    assert_nil MD.position_delta(delta: "abc", quantity: 1, multiplier: 100)
  end

  test "a real zero delta is a real zero position delta" do
    value = MD.position_delta(delta: 0.0, quantity: -2, multiplier: 100)
    refute_nil value
    assert value.zero?
    assert_kind_of BigDecimal, value
  end

  test "position_delta accepts a Result's float without noise" do
    d = compute.value
    assert_equal BigDecimal(d.to_s) * -1 * 100, MD.position_delta(delta: d, quantity: -1, multiplier: 100)
  end
end

class Options::CaveatsTest < ActiveSupport::TestCase
  test "leveraged and hard to borrow names are flagged" do
    %w[TSLL TSLS NVDL NVDX TQQQ SQQQ SOXL SOXS UVXY GME SPCX AMC].each do |symbol|
      caveats = Options::Caveats.for(underlying: symbol, itm: false, dte: 30)
      assert_includes caveats, :leveraged_or_hard_to_borrow, symbol
      assert_includes caveats, :borrow_dividends_not_modeled, symbol
    end
  end

  test "ordinary names carry no static caveats" do
    assert_equal [], Options::Caveats.for(underlying: "NVDA", itm: false, dte: 30)
    assert_equal [], Options::Caveats.for(underlying: "AAPL", itm: false, dte: 8)
  end

  test "denylist matching ignores case and padding but not substrings" do
    assert_includes Options::Caveats.for(underlying: " tsll ", itm: false, dte: 30), :leveraged_or_hard_to_borrow
    refute_includes Options::Caveats.for(underlying: "TSLA", itm: false, dte: 30), :leveraged_or_hard_to_borrow
    refute_includes Options::Caveats.for(underlying: "GMEX", itm: false, dte: 30), :leveraged_or_hard_to_borrow
  end

  test "early assignment is not modelled for in the money contracts within seven days" do
    assert_equal [ :early_assignment_not_modeled ], Options::Caveats.for(underlying: "NVDA", itm: true, dte: 7)
    assert_equal [ :early_assignment_not_modeled ], Options::Caveats.for(underlying: "NVDA", itm: true, dte: 1)
    assert_equal [ :early_assignment_not_modeled ], Options::Caveats.for(underlying: "NVDA", itm: true, dte: 0)
    assert_equal [], Options::Caveats.for(underlying: "NVDA", itm: true, dte: 8)
    assert_equal [], Options::Caveats.for(underlying: "NVDA", itm: false, dte: 3)
  end

  test "unknown itm or dte never invents an early assignment caveat" do
    assert_equal [], Options::Caveats.for(underlying: "NVDA", itm: nil, dte: 3)
    assert_equal [], Options::Caveats.for(underlying: "NVDA", itm: true, dte: nil)
  end

  test "denylist and early assignment combine" do
    caveats = Options::Caveats.for(underlying: "TSLL", itm: true, dte: 2)
    assert_includes caveats, :leveraged_or_hard_to_borrow
    assert_includes caveats, :early_assignment_not_modeled
    assert_equal caveats.uniq, caveats
    assert caveats.all?(Symbol)
  end

  test "nil underlying is not on the denylist" do
    assert_equal [], Options::Caveats.for(underlying: nil, itm: false, dte: 30)
  end
end
