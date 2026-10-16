require "test_helper"

class Options::MarkTest < ActiveSupport::TestCase
  Mark = Options::Mark
  NY = ActiveSupport::TimeZone["America/New_York"]
  Quote = Struct.new(:bid, :ask, :last_price, :last_trade_at, :quote_time, :session_date, keyword_init: true)

  setup do
    @now = NY.local(2026, 10, 15, 11, 0, 0) # Thursday, session open
    @session = Date.new(2026, 10, 15)
    @broker = BigDecimal("3.25")
  end

  def quote(overrides = {})
    Quote.new(**{
      bid: BigDecimal("7.05"), ask: BigDecimal("7.20"), last_price: BigDecimal("7.19"),
      last_trade_at: NY.local(2026, 10, 15, 10, 45), quote_time: NY.local(2026, 10, 15, 10, 55),
      session_date: @session
    }.merge(overrides))
  end

  def resolve(q, broker: @broker, current: true, now: @now)
    Mark.resolve(quote: q, broker_mark: broker, broker_snapshot_current: current, now: now)
  end

  # ---- result shape -------------------------------------------------------------------

  test "Result exposes the v2 members in order" do
    assert_equal %i[value basis source as_of stale reason bid ask], Mark::Result.members
  end

  test "aggregatable? is true only for mid, last and broker" do
    assert_same true, resolve(quote).aggregatable?
    assert_same true, resolve(quote(bid: nil, ask: nil)).aggregatable?
    assert_same true, resolve(nil).aggregatable?
    assert_same false, resolve(quote(bid: BigDecimal("1"), ask: BigDecimal("3"))).aggregatable?
    assert_same false, resolve(nil, broker: nil).aggregatable?
  end

  # ---- rule 1: session currency ------------------------------------------------------

  test "a quote from the previous session is not current and falls to the current broker snapshot" do
    result = resolve(quote(session_date: @session - 1))
    assert_equal :broker, result.basis
    assert_equal :broker_snapshot, result.source
    assert_equal @broker, result.value
    assert_equal true, result.stale
    assert_nil result.as_of
  end

  test "a stale quote with no usable broker mark is nil with reason stale_quote" do
    result = resolve(quote(session_date: @session - 1), broker: nil)
    assert_nil result.value
    assert_nil result.basis
    assert_nil result.source
    assert_equal :stale_quote, result.reason
    assert_equal true, result.stale
    assert_same false, result.aggregatable?
  end

  test "a stale quote with a non current broker snapshot is nil with reason stale_quote" do
    result = resolve(quote(session_date: @session - 1), current: false)
    assert_nil result.value
    assert_equal :stale_quote, result.reason
  end

  test "a quote without session_date is not current" do
    assert_equal :stale_quote, resolve(quote(session_date: nil), broker: nil).reason
  end

  test "the stale quote's bid and ask never leak into a Result" do
    result = resolve(quote(session_date: @session - 1), broker: nil)
    assert_nil result.bid
    assert_nil result.ask
  end

  test "friday settle viewed on monday 07:00 ET is current but monday's own quote is not before the open" do
    monday_early = NY.local(2026, 10, 19, 7, 0)
    friday_quote = quote(session_date: Date.new(2026, 10, 16), last_trade_at: NY.local(2026, 10, 16, 15, 59),
                         quote_time: NY.local(2026, 10, 16, 16, 20))
    assert_equal :mid, resolve(friday_quote, now: monday_early).basis
    assert_equal :stale_quote, resolve(friday_quote, now: NY.local(2026, 10, 19, 9, 30), broker: nil).reason
  end

  test "good friday weekend keeps thursday's quote current until monday's open" do
    thursday = quote(session_date: Date.new(2026, 4, 2), last_trade_at: NY.local(2026, 4, 2, 15, 0), quote_time: NY.local(2026, 4, 2, 16, 20))
    assert_equal :mid, resolve(thursday, now: NY.local(2026, 4, 3, 12, 0)).basis
    assert_equal :mid, resolve(thursday, now: NY.local(2026, 4, 6, 8, 0)).basis
    assert_equal :stale_quote, resolve(thursday, now: NY.local(2026, 4, 6, 9, 30), broker: nil).reason
  end

  test "thanksgiving friday needs a friday session quote after the open" do
    wednesday = quote(session_date: Date.new(2026, 11, 25), last_trade_at: NY.local(2026, 11, 25, 15, 0), quote_time: NY.local(2026, 11, 25, 16, 20))
    assert_equal :mid, resolve(wednesday, now: NY.local(2026, 11, 26, 11, 0)).basis
    assert_equal :mid, resolve(wednesday, now: NY.local(2026, 11, 27, 9, 29)).basis
    assert_equal :stale_quote, resolve(wednesday, now: NY.local(2026, 11, 27, 9, 30), broker: nil).reason
  end

  test "friday evening new york after the utc date flip still sees the friday quote as current" do
    friday_quote = quote(session_date: Date.new(2026, 10, 16), last_trade_at: NY.local(2026, 10, 16, 15, 59), quote_time: NY.local(2026, 10, 16, 16, 20))
    late = NY.local(2026, 10, 16, 22, 30)
    assert_equal Date.new(2026, 10, 17), late.utc.to_date
    assert_equal :mid, resolve(friday_quote, now: late.utc).basis
  end

  # ---- rule 2: mid / indicative ------------------------------------------------------

  test "a tight two sided market gives the mid with basis mid and source market_quote" do
    result = resolve(quote(bid: BigDecimal("7.05"), ask: BigDecimal("7.20")))
    assert_equal BigDecimal("7.125"), result.value
    assert_kind_of BigDecimal, result.value
    assert_equal :mid, result.basis
    assert_equal :market_quote, result.source
    assert_equal false, result.stale
    assert_nil result.reason
    assert_equal BigDecimal("7.05"), result.bid
    assert_equal BigDecimal("7.20"), result.ask
  end

  test "as_of is the quote_time and never a fetch time" do
    assert_equal NY.local(2026, 10, 15, 10, 55), resolve(quote).as_of
    assert_nil resolve(quote(quote_time: nil)).as_of
  end

  test "spread tolerance is 25 percent of mid for ordinary prices" do
    # bid 1.00 ask 1.28 -> spread .28, mid 1.14 -> 24.56 percent
    assert_equal :mid, resolve(quote(bid: BigDecimal("1.00"), ask: BigDecimal("1.28"))).basis
    # bid 1.00 ask 1.30 -> spread .30, mid 1.15 -> 26.09 percent
    assert_equal :indicative, resolve(quote(bid: BigDecimal("1.00"), ask: BigDecimal("1.30"))).basis
  end

  test "spread exactly at the tolerance is still mid" do
    # bid 1.75 ask 2.25 -> spread 0.5, mid 2.0 -> exactly 0.25
    assert_equal :mid, resolve(quote(bid: BigDecimal("1.75"), ask: BigDecimal("2.25"))).basis
  end

  test "penny options use the absolute 0.10 spread allowance" do
    # bid .01 ask .05 -> spread .04, mid .03 -> 133 percent but 0.10/mid = 3.33 so within tolerance
    assert_equal :mid, resolve(quote(bid: BigDecimal("0.01"), ask: BigDecimal("0.05"))).basis
    # bid .01 ask .20 -> spread .19 / mid .105 = 1.81 ; 0.10/.105 = 0.95 -> wide
    assert_equal :indicative, resolve(quote(bid: BigDecimal("0.01"), ask: BigDecimal("0.20"))).basis
  end

  test "a wide spread is indicative, carries the mid, and is not aggregatable" do
    result = resolve(quote(bid: BigDecimal("10"), ask: BigDecimal("20")))
    assert_equal BigDecimal("15"), result.value
    assert_equal :indicative, result.basis
    assert_equal :market_quote, result.source
    assert_same false, result.aggregatable?
    assert_equal BigDecimal("10"), result.bid
    assert_equal BigDecimal("20"), result.ask
  end

  test "an indicative market does not fall through to last or broker" do
    result = resolve(quote(bid: BigDecimal("10"), ask: BigDecimal("20"), last_price: BigDecimal("15.5")))
    assert_equal :indicative, result.basis
    assert_equal BigDecimal("15"), result.value
  end

  test "bid zero is not a two sided market" do
    result = resolve(quote(bid: BigDecimal("0"), ask: BigDecimal("0.05"), last_price: BigDecimal("0.03")))
    assert_equal :last, result.basis
    assert_equal BigDecimal("0.03"), result.value
  end

  test "ask equal to bid is not a two sided market" do
    result = resolve(quote(bid: BigDecimal("2"), ask: BigDecimal("2"), last_price: BigDecimal("2")))
    assert_equal :last, result.basis
  end

  test "floats and strings in the quote are converted to BigDecimal without noise" do
    result = resolve(quote(bid: 7.05, ask: "7.20"))
    assert_equal BigDecimal("7.125"), result.value
    assert_kind_of BigDecimal, result.bid
    assert_kind_of BigDecimal, result.ask
  end

  # ---- rule 3: last ------------------------------------------------------------------

  test "without a market the last trade of the session is used" do
    result = resolve(quote(bid: nil, ask: nil, last_price: BigDecimal("7.19")))
    assert_equal BigDecimal("7.19"), result.value
    assert_equal :last, result.basis
    assert_equal :market_quote, result.source
    assert_nil result.reason
  end

  test "a last print from an earlier session is not used even when the session_date is current" do
    result = resolve(quote(bid: nil, ask: nil, last_trade_at: NY.local(2026, 10, 14, 15, 59)), broker: nil)
    assert_nil result.value
    assert_equal :no_market, result.reason
  end

  test "last_trade_at is judged by its new york date not its utc date" do
    # 20:30 ET Thursday is 00:30 UTC Friday; still Thursday's session.
    result = resolve(quote(bid: nil, ask: nil, last_trade_at: NY.local(2026, 10, 15, 20, 30).utc))
    assert_equal :last, result.basis
    # 23:30 ET Wednesday is 03:30 UTC Thursday but still Wednesday.
    result = resolve(quote(bid: nil, ask: nil, last_trade_at: NY.local(2026, 10, 14, 23, 30).utc), broker: nil)
    assert_equal :no_market, result.reason
  end

  test "the band check applies only when both sides are present" do
    ask_only = resolve(quote(bid: nil, ask: BigDecimal("1.1"), last_price: BigDecimal("1.5")), broker: nil)
    assert_equal :last, ask_only.basis
    bid_only = resolve(quote(bid: BigDecimal("1"), ask: nil, last_price: BigDecimal("0.4")))
    assert_equal :last, bid_only.basis
  end

  test "a last print outside the band is rejected when both sides are present" do
    result = resolve(quote(bid: BigDecimal("0"), ask: BigDecimal("0.05"), last_price: BigDecimal("0.20")), broker: nil)
    assert_nil result.value
    assert_equal :no_market, result.reason
  end

  test "last on the band edges is accepted" do
    wide = { bid: BigDecimal("0"), ask: BigDecimal("0.05") }
    assert_equal :last, resolve(quote(wide.merge(last_price: BigDecimal("0")))).basis
    assert_equal :last, resolve(quote(wide.merge(last_price: BigDecimal("0.05")))).basis
  end

  test "a crossed market does not constrain the last print" do
    result = resolve(quote(bid: BigDecimal("2"), ask: BigDecimal("1"), last_price: BigDecimal("5")))
    assert_equal :last, result.basis
    assert_equal BigDecimal("5"), result.value
  end

  test "a real zero last price is kept and is not nil" do
    result = resolve(quote(bid: nil, ask: nil, last_price: BigDecimal("0")))
    assert_equal BigDecimal("0"), result.value
    refute_nil result.value
    assert_equal :last, result.basis
    assert_same true, result.aggregatable?
  end

  test "a negative last price is rejected" do
    result = resolve(quote(bid: nil, ask: nil, last_price: BigDecimal("-0.5")), broker: nil)
    assert_nil result.value
    assert_equal :no_market, result.reason
  end

  test "last without a last_trade_at cannot be proven to be from the session" do
    assert_equal :no_market, resolve(quote(bid: nil, ask: nil, last_trade_at: nil), broker: nil).reason
  end

  # ---- rule 4: broker ----------------------------------------------------------------

  test "with a current market quote the broker mark is ignored" do
    result = resolve(quote, broker: BigDecimal("3.25"))
    assert_equal :mid, result.basis
    assert_equal :market_quote, result.source
  end

  test "a current session quote with no market falls back to a current broker mark" do
    result = resolve(quote(bid: nil, ask: nil, last_price: nil))
    assert_equal :broker, result.basis
    assert_equal :broker_snapshot, result.source
    assert_equal @broker, result.value
    assert_nil result.as_of
    assert_equal false, result.stale
    assert_same true, result.aggregatable?
  end

  test "no quote at all uses the current broker mark" do
    result = resolve(nil)
    assert_equal :broker, result.basis
    assert_equal @broker, result.value
    assert_equal false, result.stale
  end

  test "a broker mark from a snapshot that is not current is never used" do
    result = resolve(nil, current: false)
    assert_nil result.value
    assert_equal :no_mark, result.reason
    result = resolve(quote(bid: nil, ask: nil, last_price: nil), current: false)
    assert_nil result.value
    assert_equal :no_market, result.reason
  end

  test "broker_snapshot_current must be exactly true" do
    assert_nil resolve(nil, current: nil).value
    assert_nil resolve(nil, current: "true").value
  end

  test "a broker mark of zero is a real zero" do
    result = resolve(nil, broker: BigDecimal("0"))
    assert_equal BigDecimal("0"), result.value
    refute_nil result.value
    assert_equal :broker, result.basis
  end

  test "no quote and no broker mark is nil with reason no_mark" do
    result = resolve(nil, broker: nil)
    assert_nil result.value
    assert_nil result.basis
    assert_nil result.source
    assert_nil result.as_of
    assert_equal :no_mark, result.reason
    assert_equal false, result.stale
  end

  test "a current quote with nothing usable and no broker mark is no_market" do
    result = resolve(quote(bid: nil, ask: nil, last_price: nil), broker: nil)
    assert_equal :no_market, result.reason
  end

  test "an unparsable broker mark is treated as absent" do
    assert_equal :no_mark, resolve(nil, broker: "abc").reason
    assert_equal :no_mark, resolve(nil, broker: Float::NAN).reason
  end

  test "broker mark strings and floats become exact BigDecimal" do
    assert_equal BigDecimal("2.15"), resolve(nil, broker: "2.15").value
    assert_equal BigDecimal("3.1"), resolve(nil, broker: 3.1).value
  end

  # ---- duck typing --------------------------------------------------------------------

  test "the quote may be a Hash with symbol keys" do
    hash = { bid: BigDecimal("7.05"), ask: BigDecimal("7.20"), session_date: @session, quote_time: NY.local(2026, 10, 15, 10, 55) }
    result = resolve(hash)
    assert_equal BigDecimal("7.125"), result.value
    assert_equal NY.local(2026, 10, 15, 10, 55), result.as_of
  end

  test "an empty hash is a quote with nothing in it" do
    assert_equal :stale_quote, resolve({}, broker: nil).reason
  end

  # ---- session_mark ----------------------------------------------------------------------

  def session_mark(overrides = {})
    Mark.session_mark(**{
      bid: BigDecimal("7.05"), ask: BigDecimal("7.20"), last_price: BigDecimal("7.19"),
      last_trade_at: NY.local(2026, 10, 15, 10, 45), session_date: @session
    }.merge(overrides))
  end

  test "session_mark is the mid for a tight market" do
    assert_equal BigDecimal("7.125"), session_mark
    assert_kind_of BigDecimal, session_mark
  end

  test "session_mark is nil for an indicative market" do
    assert_nil session_mark(bid: BigDecimal("10"), ask: BigDecimal("20"))
  end

  test "session_mark falls to the last print of that session" do
    assert_equal BigDecimal("7.19"), session_mark(bid: nil, ask: nil)
    assert_equal BigDecimal("0"), session_mark(bid: nil, ask: nil, last_price: BigDecimal("0"))
  end

  test "session_mark rejects a last print from another day or outside the band" do
    assert_nil session_mark(bid: nil, ask: nil, last_trade_at: NY.local(2026, 10, 14, 15, 0))
    assert_nil session_mark(bid: BigDecimal("0"), ask: BigDecimal("0.05"), last_price: BigDecimal("0.5"))
    assert_nil session_mark(bid: nil, ask: nil, last_trade_at: nil)
  end

  test "session_mark needs the session_date and judges the last print against it not against now" do
    assert_nil session_mark(session_date: nil, bid: nil, ask: nil)
    old = Date.new(2026, 10, 9)
    assert_equal BigDecimal("1.5"), session_mark(bid: nil, ask: nil, last_price: BigDecimal("1.5"), last_trade_at: NY.local(2026, 10, 9, 12), session_date: old)
  end

  test "session_mark of an empty row is nil" do
    assert_nil Mark.session_mark(bid: nil, ask: nil, last_price: nil, last_trade_at: nil, session_date: @session)
  end
end
