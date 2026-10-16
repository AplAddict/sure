# frozen_string_literal: true

require "test_helper"

module Options
  module Adversarial
  end
end

# Hostile DayGain tests from options-spec-v2 §1.4.
class Options::Adversarial::DayGainTest < ActiveSupport::TestCase
  Quote = Struct.new(
    :bid, :ask, :last_price, :last_trade_at, :quote_time, :session_date,
    :prev_session_mark, :prev_session_date, :change, :underlying_price,
    :underlying_prev_close, :strike, :option_type,
    keyword_init: true
  )

  setup do
    @session = Date.new(2026, 10, 15)
    @prev = Date.new(2026, 10, 14)
    @now = Time.utc(2026, 10, 15, 19, 59, 0)
    @quote_time = @now
  end

  def nvda_chain
    path = Rails.root.join("test/fixtures/files/yahoo-options-NVDA.json")
    JSON.parse(File.read(path))
  end

  def find_row(payload, contract)
    opt = payload.fetch("optionChain").fetch("result").fetch(0).fetch("options").fetch(0)
    (opt["calls"] + opt["puts"]).find { |r| r["contractSymbol"] == contract }
  end

  def mark_result(value:, basis: :mid, aggregatable: true)
    Options::Mark.resolve(
      quote: {
        bid: BigDecimal("7.05"),
        ask: BigDecimal("7.20"),
        last_price: value,
        last_trade_at: @now,
        quote_time: @quote_time,
        session_date: @session
      },
      broker_mark: nil,
      broker_snapshot_current: false,
      now: @now
    )
  end

  def quote(**overrides)
    Quote.new(
      bid: BigDecimal("7.05"),
      ask: BigDecimal("7.20"),
      last_price: BigDecimal("7.19"),
      last_trade_at: @now,
      quote_time: @quote_time,
      session_date: @session,
      prev_session_mark: BigDecimal("5.00"),
      prev_session_date: @prev,
      change: BigDecimal("1.54"),
      underlying_price: BigDecimal("217.23"),
      underlying_prev_close: BigDecimal("221.30"),
      strike: BigDecimal("215"),
      option_type: "PUT",
      **overrides
    )
  end

  def resolve(mark:, quote:, quantity:, multiplier: 100, position_changed_today: false, now: @now)
    Options::DayGain.resolve(
      mark: mark,
      quote: quote,
      quantity: quantity,
      multiplier: multiplier,
      position_changed_today: position_changed_today,
      now: now
    )
  end

  test "per_contract any nil or quantity 0 returns nil; real 0 change stays BigDecimal 0" do
    assert_nil Options::DayGain.per_contract(change: nil, quantity: 1, multiplier: 100)
    assert_nil Options::DayGain.per_contract(change: BigDecimal("1"), quantity: nil, multiplier: 100)
    assert_nil Options::DayGain.per_contract(change: BigDecimal("1"), quantity: 1, multiplier: nil)
    assert_nil Options::DayGain.per_contract(change: BigDecimal("1"), quantity: 0, multiplier: 100)
    z = Options::DayGain.per_contract(change: BigDecimal("0"), quantity: -2, multiplier: 100)
    assert_kind_of BigDecimal, z
    assert z.zero?
    refute_nil z
  end

  test "primary session-mark path sign matrix long/short x call/put" do
    mark = mark_result(value: BigDecimal("7.125"))
    # mark.value ~ 7.125, prev 5.00, delta_mark = 2.125
    [
      ["CALL", 1, BigDecimal("2.125") * 1 * 100],
      ["CALL", -1, BigDecimal("2.125") * -1 * 100],
      ["PUT", 1, BigDecimal("2.125") * 1 * 100],
      ["PUT", -1, BigDecimal("2.125") * -1 * 100]
    ].each do |type, qty, expected|
      r = resolve(mark: mark, quote: quote(option_type: type, prev_session_mark: BigDecimal("5.00")), quantity: qty)
      assert_equal :session_mark, r.basis, "#{type} qty=#{qty}"
      assert_equal expected, r.value, "#{type} qty=#{qty}"
      refute_nil r.value
    end
  end

  test "prev_session_date not exactly one trading day before latest_session falls to fallback" do
    mark = mark_result(value: BigDecimal("7.125"))
    # 2026-10-13 Tuesday -> Thursday 2026-10-15 is two trading days (Wed+Thu)
    q = quote(prev_session_date: Date.new(2026, 10, 13), prev_session_mark: BigDecimal("5.00"), change: BigDecimal("1.54"))
    r = resolve(mark: mark, quote: q, quantity: -1)
    refute_equal :session_mark, r.basis
    assert_equal :yahoo_change, r.basis
    assert_equal BigDecimal("1.54") * -1 * 100, r.value
  end

  test "position_changed_today true yields nil reason :position_changed_today" do
    mark = mark_result(value: BigDecimal("7.125"))
    r = resolve(mark: mark, quote: quote, quantity: -1, position_changed_today: true)
    assert_nil r.value
    assert_equal :position_changed_today, r.reason
    assert_nil r.basis
  end

  test "position_changed_today nil yields nil reason :position_unknown" do
    mark = mark_result(value: BigDecimal("7.125"))
    r = resolve(mark: mark, quote: quote, quantity: -1, position_changed_today: nil)
    assert_nil r.value
    assert_equal :position_unknown, r.reason
  end

  test "non-aggregatable mark yields :no_mark" do
    wide = Options::Mark.resolve(
      quote: {
        bid: BigDecimal("1"),
        ask: BigDecimal("10"),
        last_price: BigDecimal("5"),
        last_trade_at: @now,
        quote_time: @quote_time,
        session_date: @session
      },
      broker_mark: nil,
      broker_snapshot_current: false,
      now: @now
    )
    refute wide.aggregatable?
    r = resolve(mark: wide, quote: quote, quantity: -1)
    assert_nil r.value
    assert_equal :no_mark, r.reason
  end

  test "NVDA 250P +9.42, 150C -11.34, 180C -9.55 impossible-change rows produce nil via fallback" do
    payload = nvda_chain
    quote_root = payload.fetch("optionChain").fetch("result").fetch(0).fetch("quote")
    spot = BigDecimal(quote_root.fetch("regularMarketPrice").to_s)
    prev_close = BigDecimal(quote_root.fetch("regularMarketPreviousClose").to_s)
    assert_equal BigDecimal("217.23"), spot.round(2)
    assert_equal BigDecimal("221.3"), prev_close.round(1)

    rows = {
      "NVDA261113P00250000" => "PUT",
      "NVDA261113C00150000" => "CALL",
      "NVDA261113C00180000" => "CALL"
    }
    # Force fallback: omit prev_session_mark
    rows.each do |sym, type|
      raw = find_row(payload, sym)
      refute_nil raw, sym
      q = quote(
        bid: BigDecimal(raw["bid"].to_s),
        ask: BigDecimal(raw["ask"].to_s),
        last_price: BigDecimal(raw["lastPrice"].to_s),
        last_trade_at: Time.at(raw["lastTradeDate"]).utc,
        change: BigDecimal(raw["change"].to_s),
        strike: BigDecimal(raw["strike"].to_s),
        option_type: type,
        underlying_price: spot,
        underlying_prev_close: prev_close,
        prev_session_mark: nil,
        prev_session_date: nil,
        session_date: @session
      )
      mark = Options::Mark.resolve(
        quote: {
          bid: q.bid, ask: q.ask, last_price: q.last_price,
          last_trade_at: q.last_trade_at, quote_time: @quote_time, session_date: @session
        },
        broker_mark: nil,
        broker_snapshot_current: false,
        now: @now
      )
      r = resolve(mark: mark, quote: q, quantity: -1)
      assert_nil r.value, "#{sym} change=#{raw['change']} must not become a day gain"
      assert_equal :unreliable_reference, r.reason, sym
    end
  end

  test "plausible Yahoo change is accepted on the fallback path" do
    payload = nvda_chain
    raw = find_row(payload, "NVDA261113P00215000")
    q = quote(
      bid: BigDecimal(raw["bid"].to_s),
      ask: BigDecimal(raw["ask"].to_s),
      last_price: BigDecimal(raw["lastPrice"].to_s),
      last_trade_at: Time.at(raw["lastTradeDate"]).utc,
      change: BigDecimal(raw["change"].to_s),
      strike: BigDecimal("215"),
      option_type: "PUT",
      underlying_price: BigDecimal("217.23"),
      underlying_prev_close: BigDecimal("221.30"),
      prev_session_mark: nil,
      prev_session_date: nil
    )
    mark = mark_result(value: (q.bid + q.ask) / 2)
    r = resolve(mark: mark, quote: q, quantity: -1)
    assert_equal :yahoo_change, r.basis
    assert_equal BigDecimal(raw["change"].to_s) * -1 * 100, r.value
  end

  test "real 0 change is kept as BigDecimal 0 vs unknown nil" do
    mark = mark_result(value: BigDecimal("7.125"))
    q = quote(prev_session_mark: BigDecimal("7.125"), change: BigDecimal("0"))
    r = resolve(mark: mark, quote: q, quantity: 2)
    assert_equal :session_mark, r.basis
    assert_kind_of BigDecimal, r.value
    assert r.value.zero?
    refute_nil r.value

    unknown = resolve(
      mark: mark,
      quote: quote(prev_session_mark: nil, prev_session_date: nil, change: nil, last_trade_at: Time.utc(2026, 10, 1)),
      quantity: 2
    )
    assert_nil unknown.value
    refute_equal 0, unknown.value
  end

  test "Result exposes value, basis, reason" do
    r = resolve(mark: mark_result(value: BigDecimal("7.125")), quote: quote, quantity: 1)
    %i[value basis reason].each { |f| assert_respond_to r, f }
  end
end
