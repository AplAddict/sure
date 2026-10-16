# frozen_string_literal: true

require "test_helper"

module Options
  module Adversarial
  end
end

# Hostile Black-Scholes tests from options-spec-v2 §1.2. Property assertions only.
class Options::Adversarial::BlackScholesImpliedVolTest < ActiveSupport::TestCase
  def bs
    Options::BlackScholes
  end

  def discounted_intrinsic(type:, spot:, strike:, years:, rate:, dividend_yield: 0.0)
    df = Math.exp(-rate * years)
    dq = Math.exp(-dividend_yield * years)
    if type.to_s.upcase == "CALL"
      [dq * spot - df * strike, 0.0].max
    else
      [df * strike - dq * spot, 0.0].max
    end
  end

  test "implied_vol reprices within the contract tolerance across type, moneyness, years" do
    types = %w[CALL PUT call put]
    spots_strikes = [
      [100.0, 80.0],
      [100.0, 100.0],
      [100.0, 120.0],
      [217.23, 215.0],
      [50.0, 80.0]
    ]
    years_list = [0.02, 0.07956811263318113, 0.25, 1.0, 2.0]
    vols = [0.05, 0.15, 0.35, 0.8, 1.5, 3.0]
    rate = 0.04

    count = 0
    types.each do |type|
      spots_strikes.each do |spot, strike|
        years_list.each do |years|
          vols.each do |vol|
            px = bs.price(type: type, spot: spot, strike: strike, years: years, vol: vol, rate: rate, dividend_yield: 0)
            next if px.nil? || px <= 0
            solved = bs.implied_vol(type: type, spot: spot, strike: strike, years: years, price: px, rate: rate, dividend_yield: 0)
            assert_kind_of Numeric, solved, "IV nil for type=#{type} S=#{spot} K=#{strike} T=#{years} vol=#{vol} price=#{px}"
            repriced = bs.price(type: type, spot: spot, strike: strike, years: years, vol: solved, rate: rate, dividend_yield: 0)
            refute_nil repriced
            assert_in_delta px, repriced, 1e-6,
                            "reprice failed type=#{type} S=#{spot} K=#{strike} T=#{years} vol=#{vol} solved=#{solved}"
            count += 1
          end
        end
      end
    end
    assert count >= 80, "expected a dense grid of round-trips, got #{count}"
  end

  test "implied_vol is nil when price is below discounted intrinsic minus 1e-9" do
    type = "CALL"
    spot = 100.0
    strike = 50.0
    years = 1.0
    rate = 0.04
    di = discounted_intrinsic(type: type, spot: spot, strike: strike, years: years, rate: rate)
    assert di > 40
    assert_nil bs.implied_vol(type: type, spot: spot, strike: strike, years: years, price: di - 1e-6, rate: rate)
    assert_nil bs.implied_vol(type: type, spot: spot, strike: strike, years: years, price: 10.0, rate: rate)
    assert_nil bs.implied_vol(type: "PUT", spot: 50.0, strike: 100.0, years: 1.0, price: 10.0, rate: rate)
  end

  test "implied_vol is nil when price is above the vol=5.0 price" do
    args = { type: "CALL", spot: 100.0, strike: 100.0, years: 0.5, rate: 0.04, dividend_yield: 0 }
    cap = bs.price(**args, vol: 5.0)
    refute_nil cap
    assert_nil bs.implied_vol(**args, price: cap + 0.01)
    assert_nil bs.implied_vol(**args, price: cap + 10.0)
  end

  test "implied_vol and friends return nil for nil, zero, or negative inputs" do
    good = { type: "PUT", spot: 100.0, strike: 100.0, years: 0.5, vol: 0.2, rate: 0.04, dividend_yield: 0 }
    px = bs.price(**good)
    refute_nil px

    [nil, 0, 0.0, -1.0, Float::NAN, Float::INFINITY].each do |bad|
      assert_nil bs.price(**good, spot: bad), "price spot=#{bad.inspect}"
      assert_nil bs.delta(**good, spot: bad)
      assert_nil bs.implied_vol(type: "PUT", spot: bad, strike: 100.0, years: 0.5, price: px, rate: 0.04) unless bad == 0 && false
      assert_nil bs.price(**good, strike: bad)
      assert_nil bs.delta(**good, strike: bad)
      assert_nil bs.price(**good, years: bad)
      assert_nil bs.delta(**good, years: bad)
      assert_nil bs.implied_vol(type: "PUT", spot: 100.0, strike: 100.0, years: bad == 0 ? 0 : bad, price: px, rate: 0.04) if bad.nil? || (bad.is_a?(Numeric) && (bad <= 0 || !bad.finite?))
    end

    assert_nil bs.implied_vol(type: "PUT", spot: 100.0, strike: 100.0, years: 0.5, price: nil, rate: 0.04)
    assert_nil bs.implied_vol(type: "PUT", spot: 100.0, strike: 100.0, years: 0.5, price: 0.0, rate: 0.04) if discounted_intrinsic(type: "PUT", spot: 100.0, strike: 100.0, years: 0.5, rate: 0.04) > 1e-9 || true
    assert_nil bs.implied_vol(type: "PUT", spot: 100.0, strike: 100.0, years: 0.5, price: -1.0, rate: 0.04)
    assert_nil bs.delta(**good, vol: nil)
    assert_nil bs.delta(**good, vol: 0)
    assert_nil bs.delta(**good, vol: 0.01), "vol=0.01 is outside (0.01, 5.0]"
    assert_nil bs.delta(**good, vol: 5.01)
    refute_nil bs.delta(**good, vol: 5.0), "vol=5.0 is inside (0.01, 5.0]"
    refute_nil bs.delta(**good, vol: 0.0100001)
  end

  test "delta signs and bounds: calls in [0,1], puts in [-1,0]" do
    %w[CALL PUT].each do |type|
      d = bs.delta(type: type, spot: 100.0, strike: 100.0, years: 0.5, vol: 0.2, rate: 0.04, dividend_yield: 0)
      refute_nil d
      if type == "CALL"
        assert d >= 0.0, d
        assert d <= 1.0, d
      else
        assert d <= 0.0, d
        assert d >= -1.0, d
      end
    end
    deep_call = bs.delta(type: "CALL", spot: 400.0, strike: 100.0, years: 0.01, vol: 0.2, rate: 0.04)
    deep_put = bs.delta(type: "PUT", spot: 400.0, strike: 100.0, years: 0.01, vol: 0.2, rate: 0.04)
    assert_in_delta 1.0, deep_call, 0.02
    assert_in_delta 0.0, deep_put, 0.02
  end

  test "put-call delta relation at q=0 is put = call - 1 (e^{-qT}=1)" do
    args = { spot: 217.23, strike: 215.0, years: 0.07956811263318113, vol: 0.35, rate: 0.04, dividend_yield: 0 }
    c = bs.delta(type: "CALL", **args)
    p = bs.delta(type: "PUT", **args)
    assert_in_delta c - 1.0, p, 1e-8
  end

  test "keyword interface matches spec (type:, spot:, strike:, years:, vol:/price:, rate:, dividend_yield:)" do
    px = bs.price(type: "CALL", spot: 100, strike: 100, years: 1, vol: 0.2, rate: Options.risk_free_rate, dividend_yield: 0)
    iv = bs.implied_vol(type: "CALL", spot: 100, strike: 100, years: 1, price: px, rate: Options.risk_free_rate, dividend_yield: 0)
    assert_in_delta 0.2, iv, 1e-4
  end
end
