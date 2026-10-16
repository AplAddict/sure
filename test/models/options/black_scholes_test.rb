require "test_helper"

class Options::BlackScholesTest < ActiveSupport::TestCase
  BS = Options::BlackScholes

  def args(overrides = {})
    { spot: 100, strike: 100, years: 1.0, vol: 0.2, rate: 0.05 }.merge(overrides)
  end

  test "textbook reference deltas" do
    assert_in_delta 0.6368, BS.delta(type: "CALL", **args), 1e-3
    assert_in_delta(-0.3632, BS.delta(type: "PUT", **args), 1e-3)
  end

  test "textbook reference call price" do
    assert_in_delta 10.4506, BS.price(type: "CALL", **args), 1e-3
    assert_in_delta 5.5735, BS.price(type: "PUT", **args), 1e-3
  end

  test "put call parity holds for price across inputs" do
    [
      [ 100, 100, 1.0, 0.2, 0.05 ],
      [ 215.5, 200, 0.12, 0.65, 0.04 ],
      [ 18.3, 22, 0.5, 1.4, 0.03 ],
      [ 480, 350, 2.0, 0.35, 0.0 ],
      [ 50, 80, 0.08, 0.9, 0.2 ]
    ].each do |spot, strike, years, vol, rate|
      call = BS.price(type: "CALL", spot: spot, strike: strike, years: years, vol: vol, rate: rate)
      put = BS.price(type: "PUT", spot: spot, strike: strike, years: years, vol: vol, rate: rate)
      expected = spot - strike * Math.exp(-rate * years)
      assert_in_delta expected, call - put, 1e-6, "parity broke for #{[ spot, strike, years, vol, rate ].inspect}"
    end
  end

  test "call delta lies in 0..1 and put delta in -1..0" do
    [ 20, 80, 100, 130, 400 ].each do |spot|
      [ 0.05, 0.3, 1.0, 3.0 ].each do |vol|
        [ 0.01, 0.25, 2.0 ].each do |years|
          c = BS.delta(type: "CALL", spot: spot, strike: 100, years: years, vol: vol, rate: 0.04)
          p = BS.delta(type: "PUT", spot: spot, strike: 100, years: years, vol: vol, rate: 0.04)
          assert_includes 0.0..1.0, c
          assert_includes(-1.0..0.0, p)
        end
      end
    end
  end

  test "call delta minus put delta is one with zero dividend" do
    [ [ 100, 100, 1.0, 0.2 ], [ 30, 45, 0.1, 0.8 ], [ 250, 100, 0.5, 0.4 ] ].each do |spot, strike, years, vol|
      c = BS.delta(type: "CALL", spot: spot, strike: strike, years: years, vol: vol, rate: 0.04)
      p = BS.delta(type: "PUT", spot: spot, strike: strike, years: years, vol: vol, rate: 0.04)
      assert_in_delta 1.0, c - p, 1e-9
    end
  end

  test "default rate comes from Options.risk_free_rate" do
    explicit = BS.delta(type: "CALL", spot: 100, strike: 105, years: 0.1, vol: 0.3, rate: Options.risk_free_rate)
    implicit = BS.delta(type: "CALL", spot: 100, strike: 105, years: 0.1, vol: 0.3)
    assert_equal explicit, implicit
  end

  test "dividend yield lowers call delta and keeps parity delta relation" do
    base = BS.delta(type: "CALL", **args)
    with_div = BS.delta(type: "CALL", **args(dividend_yield: 0.03))
    assert_operator with_div, :<, base
  end

  test "deep in the money and out of the money limits are sane" do
    assert_operator BS.delta(type: "CALL", **args(spot: 300, strike: 100, years: 0.1)), :>, 0.999
    assert_operator BS.delta(type: "PUT", **args(spot: 300, strike: 100, years: 0.1)), :>, -0.001
    assert_operator BS.delta(type: "PUT", **args(spot: 30, strike: 100, years: 0.1)), :<, -0.999
    assert_operator BS.delta(type: "CALL", **args(spot: 30, strike: 100, years: 0.1)), :<, 0.001

    [ 1e-6, 1e6, 1e9 ].each do |spot|
      %w[CALL PUT].each do |type|
        d = BS.delta(type: type, **args(spot: spot, years: 0.0001, vol: 0.011))
        refute_nil d
        assert d.finite?
      end
    end
  end

  test "expired or non positive time returns nil" do
    assert_nil BS.delta(type: "CALL", **args(years: 0))
    assert_nil BS.delta(type: "PUT", **args(years: -0.01))
    assert_nil BS.price(type: "CALL", **args(years: 0))
    assert_nil BS.delta(type: "CALL", **args(years: nil))
  end

  test "unreliable or missing volatility returns nil" do
    [ nil, 0, 0.0, -0.3, 0.01, 5.0001, 12 ].each do |vol|
      assert_nil BS.delta(type: "CALL", **args(vol: vol)), "vol #{vol.inspect} should be nil"
      assert_nil BS.price(type: "PUT", **args(vol: vol)), "vol #{vol.inspect} should be nil"
    end
    refute_nil BS.delta(type: "CALL", **args(vol: 5.0))
    refute_nil BS.delta(type: "CALL", **args(vol: 0.0101))
  end

  test "missing or non positive spot and strike return nil" do
    [ nil, 0, -5 ].each do |bad|
      assert_nil BS.delta(type: "CALL", **args(spot: bad))
      assert_nil BS.delta(type: "CALL", **args(strike: bad))
      assert_nil BS.price(type: "PUT", **args(spot: bad))
    end
  end

  test "non finite and non numeric inputs return nil" do
    [ Float::NAN, Float::INFINITY, -Float::INFINITY, "abc", Object.new ].each do |bad|
      %i[spot strike years vol rate].each do |key|
        assert_nil BS.delta(type: "CALL", **args(key => bad)), "#{key}=#{bad.inspect} should be nil"
      end
      assert_nil BS.delta(type: "CALL", **args(dividend_yield: bad))
    end
  end

  test "accepts BigDecimal, Integer and Float inputs" do
    f = BS.delta(type: "CALL", **args)
    bd = BS.delta(type: "CALL", spot: BigDecimal("100"), strike: BigDecimal("100"), years: BigDecimal("1"), vol: BigDecimal("0.2"), rate: BigDecimal("0.05"))
    assert_in_delta f, bd, 1e-12
    assert_kind_of Float, bd
  end

  test "type is case insensitive and invalid type returns nil" do
    upper = BS.delta(type: "CALL", **args)
    assert_equal upper, BS.delta(type: "call", **args)
    assert_equal upper, BS.delta(type: "Call", **args)
    assert_equal upper, BS.delta(type: :call, **args)
    lower_put = BS.delta(type: "put", **args)
    assert_equal BS.delta(type: "PUT", **args), lower_put
    assert_nil BS.delta(type: "straddle", **args)
    assert_nil BS.delta(type: nil, **args)
    assert_nil BS.price(type: "", **args)
  end

  # ---- implied_vol ------------------------------------------------------------------------

  def iv_args(overrides = {})
    { spot: 100, strike: 105, years: 0.25, rate: 0.04 }.merge(overrides)
  end

  test "implied_vol round trips price for calls and puts across moneyness and vol" do
    [ 0.05, 0.2, 0.35, 0.8, 1.5, 3.0, 4.9 ].each do |vol|
      [ 70, 95, 100, 105, 140 ].each do |strike|
        %w[CALL PUT].each do |type|
          a = iv_args(strike: strike)
          price = BS.price(type: type, vol: vol, **a)
          next if price < 1e-4 # price insensitive to vol; not recoverable

          solved = BS.implied_vol(type: type, price: price, **a)
          refute_nil solved, "#{type} K=#{strike} vol=#{vol}"
          assert_in_delta price, BS.price(type: type, vol: solved, **a), 1e-5
        end
      end
    end
  end

  test "implied_vol recovers the vol for a vega-rich contract" do
    price = BS.price(type: "CALL", vol: 0.3, **iv_args)
    assert_in_delta 0.3, BS.implied_vol(type: "CALL", price: price, **iv_args), 1e-4
    price = BS.price(type: "PUT", vol: 0.55, **iv_args(strike: 95))
    assert_in_delta 0.55, BS.implied_vol(type: "put", price: price, **iv_args(strike: 95)), 1e-4
  end

  test "implied_vol returns a Float within the allowed vol band" do
    price = BS.price(type: "CALL", vol: 0.4, **iv_args)
    solved = BS.implied_vol(type: "CALL", price: price, **iv_args)
    assert_kind_of Float, solved
    assert_operator solved, :>, 0.01
    assert_operator solved, :<=, 5.0
  end

  test "implied_vol accepts BigDecimal and integer inputs" do
    price = BS.price(type: "CALL", vol: 0.3, **iv_args)
    solved = BS.implied_vol(type: "CALL", spot: BigDecimal("100"), strike: BigDecimal("105"), years: BigDecimal("0.25"),
                            price: BigDecimal(price.round(6).to_s), rate: BigDecimal("0.04"))
    assert_in_delta 0.3, solved, 1e-3
  end

  test "implied_vol is nil below discounted intrinsic" do
    # deep ITM call: spot 150 strike 100, intrinsic at r=0.04,t=0.25 is 150 - 100*exp(-0.01) = 50.995
    assert_nil BS.implied_vol(type: "CALL", price: 50.0, **iv_args(spot: 150, strike: 100))
    # deep ITM put: strike 150 spot 100: 150*exp(-0.01) - 100 = 48.507
    assert_nil BS.implied_vol(type: "PUT", price: 48.0, **iv_args(spot: 100, strike: 150))
  end

  test "implied_vol is nil for price zero or negative when no vol can produce it" do
    assert_nil BS.implied_vol(type: "CALL", price: -1, **iv_args)
    assert_nil BS.implied_vol(type: "PUT", price: -0.01, **iv_args)
  end

  test "implied_vol is nil when price exceeds the vol 5.0 price" do
    cap = BS.price(type: "CALL", vol: 5.0, **iv_args)
    assert_nil BS.implied_vol(type: "CALL", price: cap + 0.5, **iv_args)
    assert_nil BS.implied_vol(type: "CALL", price: 100.0, **iv_args)
    assert_nil BS.implied_vol(type: "PUT", price: 1000.0, **iv_args)
  end

  test "implied_vol is nil for a price between intrinsic and the price at the minimum vol" do
    a = iv_args(strike: 100, spot: 100)
    floor_price = BS.price(type: "CALL", vol: 0.0100001, **a)
    intrinsic = 100 - 100 * Math.exp(-0.04 * 0.25)
    between = (floor_price + intrinsic) / 2
    assert_operator floor_price - between, :>, 1e-4, "precondition"
    assert_nil BS.implied_vol(type: "CALL", price: between, **a)
  end

  test "implied_vol is nil for invalid inputs" do
    [ nil, 0, -1, Float::NAN, Float::INFINITY, "abc" ].each do |bad|
      assert_nil BS.implied_vol(type: "CALL", **iv_args, price: bad), "price=#{bad.inspect}"
      %i[spot strike years].each do |key|
        assert_nil BS.implied_vol(type: "CALL", price: 3.0, **iv_args(key => bad)), "#{key}=#{bad.inspect}"
      end
    end
    assert_nil BS.implied_vol(type: "STRADDLE", price: 3.0, **iv_args)
    assert_nil BS.implied_vol(type: nil, price: 3.0, **iv_args)
    assert_nil BS.implied_vol(type: "CALL", price: 3.0, **iv_args(rate: Float::NAN))
    assert_nil BS.implied_vol(type: "CALL", price: 3.0, **iv_args(dividend_yield: "x"))
  end

  test "implied_vol honours dividend yield" do
    price = BS.price(type: "CALL", vol: 0.3, dividend_yield: 0.03, **iv_args)
    with_div = BS.implied_vol(type: "CALL", price: price, dividend_yield: 0.03, **iv_args)
    without = BS.implied_vol(type: "CALL", price: price, **iv_args)
    assert_in_delta 0.3, with_div, 1e-4
    assert_operator without, :<, with_div
  end

  test "implied_vol default rate comes from Options.risk_free_rate" do
    price = BS.price(type: "CALL", vol: 0.3, spot: 100, strike: 105, years: 0.25)
    explicit = BS.implied_vol(type: "CALL", price: price, rate: Options.risk_free_rate, spot: 100, strike: 105, years: 0.25)
    implicit = BS.implied_vol(type: "CALL", price: price, spot: 100, strike: 105, years: 0.25)
    assert_equal explicit, implicit
  end

  test "implied_vol on the NVDA 215 put sample lands near the Yahoo figure" do
    # mid 7.125, spot 217.23, 29 trading days to 2026-11-13 close; Yahoo quotes ~0.33 IV
    years = 29.0 / 365
    solved = BS.implied_vol(type: "PUT", spot: 217.23, strike: 215, years: years, price: 7.125, rate: 0.04)
    assert_includes 0.25..0.45, solved
  end
end
