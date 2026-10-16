require "test_helper"

class Options::DayGainTest < ActiveSupport::TestCase
  test "long position gains when the contract rises" do
    assert_equal BigDecimal("150"), Options::DayGain.per_contract(change: BigDecimal("0.50"), quantity: 3, multiplier: 100)
  end

  test "short position with positive change yields a negative gain" do
    gain = Options::DayGain.per_contract(change: BigDecimal("0.50"), quantity: -2, multiplier: 100)
    assert_equal BigDecimal("-100"), gain
  end

  test "short position with negative change is a positive gain" do
    assert_equal BigDecimal("100"), Options::DayGain.per_contract(change: BigDecimal("-0.5"), quantity: -2, multiplier: 100)
  end

  test "uses the supplied multiplier rather than a fixed 100" do
    assert_equal BigDecimal("10"), Options::DayGain.per_contract(change: BigDecimal("1"), quantity: 1, multiplier: 10)
  end

  test "any nil input gives nil" do
    assert_nil Options::DayGain.per_contract(change: nil, quantity: 1, multiplier: 100)
    assert_nil Options::DayGain.per_contract(change: BigDecimal("1"), quantity: nil, multiplier: 100)
    assert_nil Options::DayGain.per_contract(change: BigDecimal("1"), quantity: 1, multiplier: nil)
  end

  test "zero change is a real BigDecimal zero not nil" do
    gain = Options::DayGain.per_contract(change: BigDecimal("0"), quantity: -4, multiplier: 100)
    assert_kind_of BigDecimal, gain
    assert gain.zero?
    refute_nil gain
  end

  test "zero quantity is nil because there is no position to gain on" do
    assert_nil Options::DayGain.per_contract(change: BigDecimal("1.2"), quantity: 0, multiplier: 100)
    assert_nil Options::DayGain.per_contract(change: BigDecimal("1.2"), quantity: BigDecimal("0"), multiplier: 100)
  end

  test "returns BigDecimal without float noise for float or string input" do
    gain = Options::DayGain.per_contract(change: 0.1, quantity: 3, multiplier: 100)
    assert_kind_of BigDecimal, gain
    assert_equal BigDecimal("30"), gain
    assert_equal BigDecimal("-2.5"), Options::DayGain.per_contract(change: "-0.25", quantity: "1", multiplier: BigDecimal("10"))
  end

  test "fractional quantity is supported" do
    assert_equal BigDecimal("25"), Options::DayGain.per_contract(change: BigDecimal("0.5"), quantity: BigDecimal("0.5"), multiplier: 100)
  end

  test "non finite or unparsable input gives nil" do
    assert_nil Options::DayGain.per_contract(change: Float::NAN, quantity: 1, multiplier: 100)
    assert_nil Options::DayGain.per_contract(change: "abc", quantity: 1, multiplier: 100)
    assert_nil Options::DayGain.per_contract(change: Float::INFINITY, quantity: 1, multiplier: 100)
  end

  # ---- DayGain.resolve (v2 1.4) ----------------------------------------------------------

  NY = ActiveSupport::TimeZone["America/New_York"]
  Mark = Options::Mark
  Quote = Struct.new(
    :bid, :ask, :last_price, :last_trade_at, :quote_time, :session_date, :prev_session_mark, :prev_session_date,
    :change, :underlying_price, :underlying_prev_close, :strike, :option_type, keyword_init: true
  )

  def now
    NY.local(2026, 10, 15, 11, 0, 0) # Thursday, open
  end

  def session
    Date.new(2026, 10, 15)
  end

  def mark_result(value: BigDecimal("7.125"), basis: :mid)
    Mark::Result.new(value: value, basis: basis, source: :market_quote, as_of: nil, stale: false, reason: nil, bid: nil, ask: nil)
  end

  # A put 215 quote: mid 7.125, previous session mark 6.00, a sane yahoo change.
  def quote(overrides = {})
    Quote.new(**{
      bid: BigDecimal("7.05"), ask: BigDecimal("7.20"), last_price: BigDecimal("7.19"),
      last_trade_at: NY.local(2026, 10, 15, 10, 45), quote_time: NY.local(2026, 10, 15, 10, 55), session_date: session,
      prev_session_mark: BigDecimal("6.00"), prev_session_date: Date.new(2026, 10, 14),
      change: BigDecimal("1.54"), underlying_price: BigDecimal("217.23"), underlying_prev_close: BigDecimal("221.30"),
      strike: BigDecimal("215"), option_type: "PUT"
    }.merge(overrides))
  end

  def resolve(q = quote, mark: mark_result, quantity: 1, multiplier: 100, changed: false, at: now)
    Options::DayGain.resolve(mark: mark, quote: q, quantity: quantity, multiplier: multiplier, position_changed_today: changed, now: at)
  end

  test "resolve Result has value basis and reason" do
    assert_equal %i[value basis reason], Options::DayGain::Result.members
  end

  test "primary basis is mark minus previous session mark times quantity times multiplier" do
    result = resolve(quantity: 3)
    assert_equal BigDecimal("337.5"), result.value
    assert_kind_of BigDecimal, result.value
    assert_equal :session_mark, result.basis
    assert_nil result.reason
  end

  test "sign matrix for long and short calls and puts when the mark rises or falls" do
    # mark up by 1.125 (6.00 -> 7.125) and down by 1.875 (9.00 -> 7.125)
    [ "CALL", "PUT" ].each do |type|
      up = quote(option_type: type)
      down = quote(option_type: type, prev_session_mark: BigDecimal("9.00"))
      assert_equal BigDecimal("112.5"), resolve(up, quantity: 1).value, "long #{type} up"
      assert_equal BigDecimal("-112.5"), resolve(up, quantity: -1).value, "short #{type} up"
      assert_equal BigDecimal("-187.5"), resolve(down, quantity: 1).value, "long #{type} down"
      assert_equal BigDecimal("187.5"), resolve(down, quantity: -1).value, "short #{type} down"
    end
  end

  test "multiplier is applied rather than assumed" do
    assert_equal BigDecimal("11.25"), resolve(quantity: 1, multiplier: 10).value
  end

  test "a real zero gain is zero and not nil" do
    result = resolve(quote(prev_session_mark: BigDecimal("7.125")), quantity: -4)
    assert_equal BigDecimal("0"), result.value
    refute_nil result.value
    assert_equal :session_mark, result.basis
    assert_nil result.reason
  end

  test "a previous session mark of zero is a real reference not a missing one" do
    result = resolve(quote(prev_session_mark: BigDecimal("0")), mark: mark_result(value: BigDecimal("0.05")))
    assert_equal BigDecimal("5"), result.value
    assert_equal :session_mark, result.basis
  end

  test "a mark value of zero still produces a gain" do
    result = resolve(quote(prev_session_mark: BigDecimal("0.25")), mark: mark_result(value: BigDecimal("0"), basis: :last), quantity: -1)
    assert_equal BigDecimal("25"), result.value
  end

  test "position changed today gives nil with that reason and unknown gives position_unknown" do
    changed = resolve(changed: true)
    assert_nil changed.value
    assert_nil changed.basis
    assert_equal :position_changed_today, changed.reason
    unknown = resolve(changed: nil)
    assert_nil unknown.value
    assert_equal :position_unknown, unknown.reason
  end

  test "a mark that is not aggregatable gives no_mark" do
    [ mark_result(basis: :indicative), mark_result(value: nil, basis: nil) ].each do |m|
      result = resolve(mark: m)
      assert_nil result.value
      assert_equal :no_mark, result.reason
    end
  end

  test "missing quantity multiplier or a zero quantity give nil" do
    assert_nil resolve(quantity: nil).value
    assert_nil resolve(quantity: 0).value
    assert_nil resolve(multiplier: nil).value
    assert_equal :no_quantity, resolve(quantity: 0).reason
    assert_equal :no_quantity, resolve(quantity: nil).reason
    assert_equal :no_multiplier, resolve(multiplier: nil).reason
  end

  test "the previous session must be exactly one trading day before the latest session" do
    two_back = resolve(quote(prev_session_date: Date.new(2026, 10, 13), change: nil))
    assert_nil two_back.value
    assert_equal :unreliable_reference, two_back.reason
    same_day = resolve(quote(prev_session_date: session, change: nil))
    assert_nil same_day.value
    missing_date = resolve(quote(prev_session_date: nil, change: nil))
    assert_nil missing_date.value
    missing_mark = resolve(quote(prev_session_mark: nil, change: nil))
    assert_nil missing_mark.value
  end

  test "friday to monday counts as one trading day" do
    monday = NY.local(2026, 10, 19, 10, 0)
    q = quote(session_date: Date.new(2026, 10, 19), prev_session_date: Date.new(2026, 10, 16),
              last_trade_at: NY.local(2026, 10, 19, 9, 45), quote_time: NY.local(2026, 10, 19, 9, 55))
    result = resolve(q, at: monday)
    assert_equal :session_mark, result.basis
    assert_equal BigDecimal("112.5"), result.value
  end

  test "friday settle viewed monday 07:00 ET compares friday with thursday" do
    early = NY.local(2026, 10, 19, 7, 0)
    q = quote(session_date: Date.new(2026, 10, 16), prev_session_date: Date.new(2026, 10, 15),
              last_trade_at: NY.local(2026, 10, 16, 15, 50), quote_time: NY.local(2026, 10, 16, 16, 20))
    result = resolve(q, at: early)
    assert_equal :session_mark, result.basis
    assert_equal BigDecimal("112.5"), result.value
    # a reference from two sessions back is not adjacent to Friday
    stale_ref = quote(session_date: Date.new(2026, 10, 16), prev_session_date: Date.new(2026, 10, 14), change: nil,
                      last_trade_at: NY.local(2026, 10, 16, 15, 50))
    assert_nil resolve(stale_ref, at: early).value
  end

  test "good friday: thursday to monday is one trading day" do
    monday = NY.local(2026, 4, 6, 10, 0)
    q = quote(session_date: Date.new(2026, 4, 6), prev_session_date: Date.new(2026, 4, 2),
              last_trade_at: NY.local(2026, 4, 6, 9, 45))
    assert_equal :session_mark, resolve(q, at: monday).basis
    wed = quote(session_date: Date.new(2026, 4, 6), prev_session_date: Date.new(2026, 4, 1), change: nil,
                last_trade_at: NY.local(2026, 4, 6, 9, 45))
    assert_nil resolve(wed, at: monday).value
  end

  test "thanksgiving: wednesday to friday is one trading day" do
    friday = NY.local(2026, 11, 27, 10, 0)
    q = quote(session_date: Date.new(2026, 11, 27), prev_session_date: Date.new(2026, 11, 25),
              last_trade_at: NY.local(2026, 11, 27, 9, 45))
    assert_equal :session_mark, resolve(q, at: friday).basis
  end

  test "juneteenth 2027 observed on friday: thursday to monday is one trading day" do
    monday = NY.local(2027, 6, 21, 10, 0)
    q = quote(session_date: Date.new(2027, 6, 21), prev_session_date: Date.new(2027, 6, 17),
              last_trade_at: NY.local(2027, 6, 21, 9, 45))
    assert_equal :session_mark, resolve(q, at: monday).basis
  end

  test "dst transition: sunday 2026-03-08 and 2026-11-01 do not disturb session adjacency" do
    mon = NY.local(2026, 3, 9, 10, 0)
    q = quote(session_date: Date.new(2026, 3, 9), prev_session_date: Date.new(2026, 3, 6), last_trade_at: NY.local(2026, 3, 9, 9, 45))
    assert_equal :session_mark, resolve(q, at: mon).basis
    mon = NY.local(2026, 11, 2, 10, 0)
    q = quote(session_date: Date.new(2026, 11, 2), prev_session_date: Date.new(2026, 10, 30), last_trade_at: NY.local(2026, 11, 2, 9, 45))
    assert_equal :session_mark, resolve(q, at: mon).basis
  end

  # ---- yahoo change fallback ---------------------------------------------------------

  def fallback_quote(overrides = {})
    quote({ prev_session_mark: nil, prev_session_date: nil }.merge(overrides))
  end

  test "fallback uses the yahoo change when every reliability check passes" do
    result = resolve(fallback_quote, quantity: -2)
    assert_equal BigDecimal("-308"), result.value
    assert_equal :yahoo_change, result.basis
    assert_nil result.reason
  end

  test "fallback applies when the primary reference is not adjacent" do
    result = resolve(quote(prev_session_date: Date.new(2026, 10, 13)))
    assert_equal :yahoo_change, result.basis
    assert_equal BigDecimal("154"), result.value
  end

  test "primary wins over fallback when both could apply" do
    assert_equal :session_mark, resolve(quote).basis
  end

  test "fallback requires the quote to be from the latest session" do
    result = resolve(fallback_quote(session_date: session - 1))
    assert_nil result.value
    assert_equal :unreliable_reference, result.reason
  end

  test "fallback requires a two sided market" do
    [ { bid: nil }, { ask: nil }, { bid: BigDecimal("0") }, { bid: BigDecimal("7.2"), ask: BigDecimal("7.2") } ].each do |o|
      result = resolve(fallback_quote(o))
      assert_nil result.value, o.inspect
      assert_equal :unreliable_reference, result.reason
    end
  end

  test "fallback requires the last trade to be on the latest session" do
    [ NY.local(2026, 10, 14, 15, 59), nil ].each do |t|
      result = resolve(fallback_quote(last_trade_at: t))
      assert_nil result.value
      assert_equal :unreliable_reference, result.reason
    end
  end

  test "fallback rejects a change larger than the underlying move plus five cents" do
    # underlying moved 4.07
    assert_equal :yahoo_change, resolve(fallback_quote(change: BigDecimal("4.12"), last_price: BigDecimal("7.19"))).basis
    assert_nil resolve(fallback_quote(change: BigDecimal("4.13"))).value
    assert_nil resolve(fallback_quote(change: BigDecimal("-4.13"))).value
  end

  test "fallback uses the absolute underlying move so a rising underlying works too" do
    q = fallback_quote(underlying_price: BigDecimal("221.30"), underlying_prev_close: BigDecimal("217.23"), change: BigDecimal("-4.0"),
                       last_price: BigDecimal("12.0"))
    assert_equal :yahoo_change, resolve(q).basis
  end

  test "fallback rejects a previous price below intrinsic value" do
    # call 180 with prev close 221.30 has intrinsic 41.30; last 39.0 - (-9.55)=48.55 is fine but last 30 - 0 = 30 is not
    q = fallback_quote(option_type: "CALL", strike: BigDecimal("180"), last_price: BigDecimal("30.0"), change: BigDecimal("0.5"),
                       bid: BigDecimal("29.5"), ask: BigDecimal("30.5"))
    result = resolve(q)
    assert_nil result.value
    assert_equal :unreliable_reference, result.reason
  end

  test "fallback intrinsic check allows five cents of slack" do
    q = fallback_quote(option_type: "CALL", strike: BigDecimal("180"), last_price: BigDecimal("41.30"), change: BigDecimal("0.05"),
                       bid: BigDecimal("41.2"), ask: BigDecimal("41.4"))
    # prev price 41.25 >= 41.30 - 0.05
    assert_equal :yahoo_change, resolve(q).basis
    q.last_price = BigDecimal("41.29")
    assert_nil resolve(q).value
  end

  test "fallback needs every input it checks" do
    %i[change underlying_price underlying_prev_close last_price strike option_type].each do |key|
      result = resolve(fallback_quote(key => nil))
      assert_nil result.value, "#{key} nil"
      assert_equal :unreliable_reference, result.reason, "#{key} nil"
    end
  end

  test "a real zero yahoo change is a real zero gain" do
    result = resolve(fallback_quote(change: BigDecimal("0")), quantity: 5)
    assert_equal BigDecimal("0"), result.value
    refute_nil result.value
    assert_equal :yahoo_change, result.basis
  end

  test "fallback sign matrix: short positions invert the yahoo change" do
    assert_equal BigDecimal("154"), resolve(fallback_quote, quantity: 1).value
    assert_equal BigDecimal("-154"), resolve(fallback_quote, quantity: -1).value
    assert_equal BigDecimal("-154"), resolve(fallback_quote(change: BigDecimal("-1.54")), quantity: 1).value
    assert_equal BigDecimal("154"), resolve(fallback_quote(change: BigDecimal("-1.54")), quantity: -1).value
  end

  test "hash quotes work" do
    h = quote.to_h
    assert_equal BigDecimal("112.5"), resolve(h).value
  end

  # ---- REGRESSION: impossible Yahoo change rows from the real NVDA sample ---------------

  def sample_quotes
    raw = JSON.parse(file_fixture("yahoo-options-NVDA.json").read)
    result = raw.fetch("optionChain").fetch("result").first
    underlying = result.fetch("quote")
    quote_time = Time.at(underlying.fetch("regularMarketTime")).utc
    chain = result.fetch("options").first
    rows = (chain.fetch("calls") + chain.fetch("puts")).map do |c|
      [ c.fetch("contractSymbol"), Quote.new(
        bid: BigDecimal(c["bid"].to_s), ask: BigDecimal(c["ask"].to_s), last_price: BigDecimal(c["lastPrice"].to_s),
        last_trade_at: Time.at(c.fetch("lastTradeDate")).utc, quote_time: quote_time,
        session_date: Options::MarketCalendar.market_date(quote_time),
        change: BigDecimal(c["change"].to_s).round(2), underlying_price: BigDecimal(underlying["regularMarketPrice"].to_s),
        underlying_prev_close: BigDecimal(underlying["regularMarketPreviousClose"].to_s),
        strike: BigDecimal(c["strike"].to_s), option_type: c.fetch("contractSymbol")[-9] == "C" ? "CALL" : "PUT"
      ) ]
    end
    [ rows.to_h, quote_time + 20.minutes ]
  end

  test "NVDA sample 250P 150C and 180C with an impossible change are nil via the fallback" do
    quotes, at = sample_quotes
    assert_equal BigDecimal("217.23"), quotes.values.first.underlying_price
    assert_equal BigDecimal("221.3"), quotes.values.first.underlying_prev_close
    {
      "NVDA261113P00250000" => BigDecimal("9.42"),
      "NVDA261113C00150000" => BigDecimal("-11.34"),
      "NVDA261113C00180000" => BigDecimal("-9.55")
    }.each do |symbol, change|
      q = quotes.fetch(symbol)
      assert_equal change, q.change, symbol
      [ 1, -1, 3 ].each do |quantity|
        result = resolve(q, quantity: quantity, at: at)
        assert_nil result.value, "#{symbol} qty #{quantity}"
        assert_nil result.basis
        assert_equal :unreliable_reference, result.reason
      end
    end
  end

  test "NVDA sample rows with a believable change still produce the yahoo fallback gain" do
    quotes, at = sample_quotes
    put = resolve(quotes.fetch("NVDA261113P00215000"), quantity: -1, at: at)
    assert_equal :yahoo_change, put.basis
    assert_equal BigDecimal("-154"), put.value
    call = resolve(quotes.fetch("NVDA261113C00215000"), quantity: 1, at: at)
    assert_equal BigDecimal("-235"), call.value
  end

  test "across the whole NVDA sample no accepted fallback exceeds the underlying move" do
    quotes, at = sample_quotes
    results = quotes.transform_values { |q| [ q, resolve(q, quantity: 1, at: at) ] }
    accepted = results.values.select { |_, r| r.basis == :yahoo_change }
    assert_operator accepted.size, :>, 5
    accepted.each { |q, r| assert_operator r.value.abs / 100, :<=, (q.underlying_price - q.underlying_prev_close).abs + BigDecimal("0.05") }
    assert_operator results.values.count { |_, r| r.value.nil? }, :>=, 3
  end
end
