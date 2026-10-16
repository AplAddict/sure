# frozen_string_literal: true

require "test_helper"

module Options
  module Adversarial
  end
end

# Hostile Mark tests from options-spec-v2 §1.3. Do not use round-1 today:/fetched_at API.
class Options::Adversarial::MarkTest < ActiveSupport::TestCase
  Quote = Struct.new(
    :bid, :ask, :last_price, :last_trade_at, :quote_time, :session_date,
    keyword_init: true
  )

  def ny(y, m, d, hh, mm, ss = 0)
    Time.find_zone!("America/New_York").local(y, m, d, hh, mm, ss)
  end

  setup do
    @session = Date.new(2026, 10, 15) # Thursday
    @quote_time = Time.utc(2026, 10, 15, 19, 59, 0)
    @now = Time.utc(2026, 10, 15, 19, 59, 0) # 15:59 EDT, session open
  end

  def q(**overrides)
    Quote.new(
      bid: BigDecimal("7.05"),
      ask: BigDecimal("7.20"),
      last_price: BigDecimal("7.19"),
      last_trade_at: Time.utc(2026, 10, 15, 19, 59, 38),
      quote_time: @quote_time,
      session_date: @session,
      **overrides
    )
  end

  def resolve(quote: q, broker_mark: nil, broker_snapshot_current: false, now: @now)
    Options::Mark.resolve(
      quote: quote,
      broker_mark: broker_mark,
      broker_snapshot_current: broker_snapshot_current,
      now: now
    )
  end

  test "tight two-sided market uses mid, basis :mid, source :market_quote, aggregatable" do
    r = resolve
    assert_equal :mid, r.basis
    assert_equal :market_quote, r.source
    assert r.aggregatable?
    expected = (BigDecimal("7.05") + BigDecimal("7.20")) / 2
    assert_equal expected, r.value
    assert_equal @quote_time, r.as_of
    assert_equal false, r.stale
    assert_equal BigDecimal("7.05"), r.bid
    assert_equal BigDecimal("7.20"), r.ask
  end

  test "wide spread still returns mid but basis :indicative and not aggregatable" do
    # (ask-bid)/mid <= max(0.25, 0.10/mid); 4/6 ≈ 0.667 > 0.25
    r = resolve(quote: q(bid: BigDecimal("4"), ask: BigDecimal("8"), last_price: BigDecimal("5")))
    assert_equal :indicative, r.basis
    assert_equal :market_quote, r.source
    refute r.aggregatable?
    assert_equal BigDecimal("6"), r.value
    assert_equal @quote_time, r.as_of
  end

  test "cheap option allows relative spread above 0.25 when 0.10/mid is larger" do
    # mid=0.20, 0.10/mid=0.50, (0.28-0.12)/0.20=0.80 > 0.50 -> indicative
    wide = resolve(quote: q(bid: BigDecimal("0.12"), ask: BigDecimal("0.28"), last_price: BigDecimal("0.20")))
    assert_equal :indicative, wide.basis
    refute wide.aggregatable?
    # (0.24-0.16)/0.20=0.40 <= 0.50 -> mid
    tight = resolve(quote: q(bid: BigDecimal("0.16"), ask: BigDecimal("0.24"), last_price: BigDecimal("0.20")))
    assert_equal :mid, tight.basis
    assert tight.aggregatable?
  end

  test "last inside bid/ask on the same session is used when two-sided mid rule fails" do
    # bid not > 0
    r = resolve(quote: q(bid: BigDecimal("0"), ask: BigDecimal("7.20"), last_price: BigDecimal("7.19")))
    assert_equal :last, r.basis
    assert_equal :market_quote, r.source
    assert r.aggregatable?
    assert_equal BigDecimal("7.19"), r.value
    assert_equal @quote_time, r.as_of
  end

  test "last outside [bid, ask] is rejected when bid/ask present and ask >= bid" do
    # Skip the mid path (bid must be > 0 for mid). bid=0, ask=7.20, last=9.50 is outside [0, 7.20].
    r = resolve(quote: q(bid: BigDecimal("0"), ask: BigDecimal("7.20"), last_price: BigDecimal("9.50")))
    assert_nil r.value
    refute_equal :last, r.basis
    refute r.aggregatable?
    assert_includes %i[no_market no_mark], r.reason
  end

  test "last printed days ago is rejected even if quote_time/fetch is recent" do
    old_last = Time.utc(2026, 10, 10, 19, 0, 0) # previous week
    r = resolve(
      quote: q(
        bid: BigDecimal("0"),
        ask: BigDecimal("0"),
        last_price: BigDecimal("7.19"),
        last_trade_at: old_last,
        quote_time: @quote_time
      )
    )
    assert_nil r.value
    refute_equal :last, r.basis
  end

  test "real 0.00 last is kept as a numeric zero, not nil" do
    r = resolve(
      quote: q(
        bid: nil,
        ask: nil,
        last_price: BigDecimal("0.00"),
        last_trade_at: Time.utc(2026, 10, 15, 18, 0, 0)
      )
    )
    assert_equal :last, r.basis
    assert r.aggregatable?
    assert_equal BigDecimal("0.00"), r.value
    refute_nil r.value
    assert r.value.zero?
  end

  test "bid 0 with positive ask is not a two-sided mid; falls through to last or nil" do
    r = resolve(quote: q(bid: BigDecimal("0"), ask: BigDecimal("1.50"), last_price: BigDecimal("1.20")))
    assert_equal :last, r.basis
    assert_equal BigDecimal("1.20"), r.value
  end

  test "crossed market (ask < bid) is not a mid" do
    r = resolve(quote: q(bid: BigDecimal("7.50"), ask: BigDecimal("7.00"), last_price: nil))
    refute_equal :mid, r.basis
    refute_equal :indicative, r.basis
    assert_nil r.value
  end

  test "nil everything yields nil value and reason :no_market or :no_mark, not a fake zero" do
    r = resolve(
      quote: q(bid: nil, ask: nil, last_price: nil, last_trade_at: nil, quote_time: nil, session_date: @session),
      broker_mark: nil,
      broker_snapshot_current: false
    )
    assert_nil r.value
    assert_nil r.basis
    assert_includes %i[no_market no_mark], r.reason
    refute_equal 0, r.value
  end

  test "broker mark is used only when broker_snapshot_current is true" do
    dead = q(bid: nil, ask: nil, last_price: nil, last_trade_at: nil)
    skipped = resolve(quote: dead, broker_mark: BigDecimal("3.25"), broker_snapshot_current: false)
    assert_nil skipped.value
    refute_equal :broker, skipped.basis

    used = resolve(quote: dead, broker_mark: BigDecimal("3.25"), broker_snapshot_current: true)
    assert_equal :broker, used.basis
    assert_equal :broker_snapshot, used.source
    assert used.aggregatable?
    assert_equal BigDecimal("3.25"), used.value
    assert_nil used.as_of
  end

  test "broker is not used when a current aggregatable mid exists even if broker_snapshot_current" do
    r = resolve(quote: q, broker_mark: BigDecimal("3.25"), broker_snapshot_current: true)
    assert_equal :mid, r.basis
    refute_equal :broker, r.basis
  end

  test "Friday session viewed Monday pre-open is the latest session so the quote is NOT stale" do
    friday = Date.new(2026, 10, 16)
    quote = q(
      session_date: friday,
      quote_time: Time.utc(2026, 10, 16, 19, 59, 0),
      last_trade_at: Time.utc(2026, 10, 16, 19, 50, 0)
    )
    now = Time.utc(2026, 10, 19, 13, 0, 0) # Monday 09:00 EDT, before open
    r = resolve(quote: quote, now: now)
    refute_equal :stale_quote, r.reason
    assert_equal false, r.stale
    assert_equal :mid, r.basis
    assert_equal quote.quote_time, r.as_of
  end

  test "Thursday quote viewed Monday is stale_quote" do
    quote = q(session_date: Date.new(2026, 10, 15), quote_time: Time.utc(2026, 10, 15, 19, 59, 0))
    now = Time.utc(2026, 10, 19, 14, 0, 0) # Monday 10:00 EDT, latest_session=Monday
    r = resolve(quote: quote, now: now, broker_mark: nil, broker_snapshot_current: false)
    assert_equal :stale_quote, r.reason
    assert_equal true, r.stale
    refute r.aggregatable?
    assert_nil r.value
  end

  test "as_of equals quote_time never a fetch clock" do
    qt = Time.utc(2026, 10, 15, 18, 12, 9)
    r = resolve(quote: q(quote_time: qt))
    assert_equal qt, r.as_of
  end

  test "Hash quote duck type is accepted with the same mid path" do
    r = resolve(
      quote: {
        bid: BigDecimal("7.05"),
        ask: BigDecimal("7.20"),
        last_price: BigDecimal("7.19"),
        last_trade_at: Time.utc(2026, 10, 15, 19, 59, 38),
        quote_time: @quote_time,
        session_date: @session
      }
    )
    assert_equal :mid, r.basis
    assert_equal @quote_time, r.as_of
  end

  test "session_mark applies rules 2-3 only and returns nil for indicative" do
    mid = Options::Mark.session_mark(
      bid: BigDecimal("7.05"),
      ask: BigDecimal("7.20"),
      last_price: BigDecimal("7.19"),
      last_trade_at: Time.utc(2026, 10, 15, 19, 59, 38),
      session_date: @session
    )
    assert_equal (BigDecimal("7.05") + BigDecimal("7.20")) / 2, mid

    indicative = Options::Mark.session_mark(
      bid: BigDecimal("1"),
      ask: BigDecimal("10"),
      last_price: BigDecimal("5"),
      last_trade_at: Time.utc(2026, 10, 15, 19, 0, 0),
      session_date: @session
    )
    assert_nil indicative

    last = Options::Mark.session_mark(
      bid: BigDecimal("0"),
      ask: BigDecimal("2"),
      last_price: BigDecimal("1.10"),
      last_trade_at: Time.utc(2026, 10, 15, 18, 0, 0),
      session_date: @session
    )
    assert_equal BigDecimal("1.10"), last
  end

  test "Result fields are value, basis, source, as_of, stale, reason, bid, ask" do
    r = resolve
    %i[value basis source as_of stale reason bid ask].each do |field|
      assert_respond_to r, field
    end
    assert_respond_to r, :aggregatable?
  end
end
