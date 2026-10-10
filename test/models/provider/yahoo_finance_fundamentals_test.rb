require "test_helper"

class Provider::YahooFinanceFundamentalsTest < ActiveSupport::TestCase
  setup { @provider = Provider::YahooFinance.new }

  def raw(value) = { "raw" => value, "fmt" => value.to_s }

  test "parses figures, keeps missing ones nil and picks the next future earnings date" do
    future = (Date.current + 20).to_time(:utc).to_i
    past = (Date.current - 40).to_time(:utc).to_i
    result = {
      "price" => { "currency" => "USD", "marketCap" => raw(4_900_000_000_000) },
      "summaryDetail" => { "trailingPE" => raw(38.6), "dividendYield" => raw(0.0032), "forwardPE" => {} },
      "financialData" => { "profitMargins" => raw(0.276), "recommendationKey" => "buy", "numberOfAnalystOpinions" => raw(39) },
      "recommendationTrend" => { "trend" => [ { "strongBuy" => 6, "buy" => 19, "hold" => 13, "sell" => 3, "strongSell" => 3 } ] },
      "calendarEvents" => { "earnings" => { "earningsDate" => [ raw(past), raw(future) ] } }
    }

    data = @provider.send(:parse_fundamentals, result)

    assert_equal 38.6, data["trailing_pe"]
    assert_equal 4_900_000_000_000, data["market_cap"]
    assert_nil data["forward_pe"]
    assert_nil data["beta"]
    assert_equal "buy", data["recommendation"]
    assert_equal 6, data["strong_buy"]
    assert_equal (Date.current + 20).iso8601, data["next_earnings_date"]
  end

  test "no future earnings date means unavailable" do
    past = (Date.current - 40).to_time(:utc).to_i
    data = @provider.send(:parse_fundamentals, { "calendarEvents" => { "earnings" => { "earningsDate" => [ raw(past) ] } } })

    assert_nil data["next_earnings_date"]
  end

  test "a 429 becomes a rate limit error" do
    @provider.stubs(:fetch_cookie_and_crumb).returns([ "c", "k" ])
    @provider.stubs(:throttle_request)
    @provider.stubs(:request_fundamentals).raises(Faraday::TooManyRequestsError.new("429"))

    response = @provider.fetch_security_fundamentals(symbol: "AAPL")

    assert_not response.success?
    assert_match(/429/, response.error.message)
  end
end
