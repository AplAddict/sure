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

  test "reads a stock's quote type, sector and industry from the profile" do
    data = @provider.send(:parse_fundamentals, {
      "price" => { "quoteType" => "EQUITY" },
      "assetProfile" => { "sector" => "Technology", "industry" => "Consumer Electronics" }
    })

    assert_equal "EQUITY", data["quote_type"]
    assert_equal "Technology", data["sector"]
    assert_equal "Consumer Electronics", data["industry"]
    assert_nil data["fund_sectors"]
    assert_nil data["fund_mix"]
  end

  test "reads a fund's sector weights and asset mix, naming sectors as stocks do" do
    data = @provider.send(:parse_fundamentals, {
      "price" => { "quoteType" => "ETF" },
      "topHoldings" => {
        "stockPosition" => raw(0.9987), "bondPosition" => raw(0.0), "cashPosition" => raw(0.0013),
        "sectorWeightings" => [
          { "technology" => raw(0.52) }, { "realestate" => raw(0.023) }, { "consumer_cyclical" => raw(0.101) }, { "something_new" => raw(0.01) }
        ]
      }
    })

    assert_equal({ "Technology" => 0.52, "Real Estate" => 0.023, "Consumer Cyclical" => 0.101 }, data["fund_sectors"])
    assert_equal({ "stock" => 0.9987, "bond" => 0.0, "cash" => 0.0013 }, data["fund_mix"])
  end

  test "a fund without sector weights or mix has none rather than zero" do
    data = @provider.send(:parse_fundamentals, { "price" => { "quoteType" => "ETF" }, "topHoldings" => { "sectorWeightings" => [] } })

    assert_nil data["fund_sectors"]
    assert_nil data["fund_mix"]
  end

  test "asks for the profile and top-holdings modules in the same request" do
    assert_match(/assetProfile/, Provider::YahooFinance::FUNDAMENTAL_MODULES)
    assert_match(/topHoldings/, Provider::YahooFinance::FUNDAMENTAL_MODULES)
  end
end
