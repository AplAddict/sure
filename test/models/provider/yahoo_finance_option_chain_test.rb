require "test_helper"

class Provider::YahooFinanceOptionChainTest < ActiveSupport::TestCase
  CHAIN_URL = "https://query1.finance.yahoo.com/v7/finance/options/NVDA"
  RIVN_URL = "https://query1.finance.yahoo.com/v7/finance/options/RIVN"

  setup do
    @provider = Provider::YahooFinance.new
    @provider.stubs(:throttle_request)
    # Deliberately NOT stubbing max_retries: the default (5) must not apply to
    # this endpoint. The interval is shrunk only so a regression fails fast.
    @provider.stubs(:retry_interval).returns(0.001)
    @provider.stubs(:fetch_cookie_and_crumb).returns([ "cookie", "crumb" ])
  end

  def sample(symbol) = File.read(file_fixture("yahoo-options-#{symbol}.json"))

  def row(data, symbol) = data[:rows].find { |r| r[:contract_symbol] == symbol }

  test "parses the real NVDA chain into the put's contract figures" do
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: sample("NVDA"))

    response = @provider.fetch_option_chain(symbol: "NVDA")

    assert response.success?, response.error&.message
    data = response.data
    assert_equal BigDecimal("217.23"), data[:underlying_price]
    assert_equal 25, data[:expirations].size
    assert data[:expirations].all?(Date)

    put = row(data, "NVDA261113P00215000")
    assert_equal "NVDA", put[:underlying]
    assert_equal "PUT", put[:option_type]
    assert_equal BigDecimal("215"), put[:strike]
    assert_equal Date.new(2026, 11, 13), put[:expiration]
    assert_in_delta 0.3346, put[:implied_volatility], 0.0001
    assert_equal 2198, put[:open_interest]
    assert_equal BigDecimal("1.54"), put[:change]
    assert_equal BigDecimal("7.19"), put[:last_price]
    assert_equal BigDecimal("7.05"), put[:bid]
    assert_equal BigDecimal("7.2"), put[:ask]
    assert_equal Time.at(1792094378).utc, put[:last_trade_at]
    assert_equal "USD", put[:currency]
    assert_equal 39 + 45, data[:rows].size
    assert_equal %w[CALL PUT], data[:rows].map { |r| r[:option_type] }.uniq.sort
  end

  test "money fields are BigDecimal, never Float" do
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: sample("NVDA"))

    put = row(@provider.fetch_option_chain(symbol: "NVDA").data, "NVDA261113P00215000")

    %i[strike last_price bid ask change percent_change].each { |field| assert_kind_of BigDecimal, put[field], field }
  end

  test "a missing numeric field is nil, never zero" do
    body = JSON.parse(sample("NVDA"))
    contract = body.dig("optionChain", "result", 0, "options", 0, "puts").find { |c| c["contractSymbol"] == "NVDA261113P00215000" }
    contract.delete("volume")
    contract.delete("bid")
    contract["openInterest"] = nil
    contract["impliedVolatility"] = "n/a"
    contract.delete("lastTradeDate")
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: body.to_json)

    put = row(@provider.fetch_option_chain(symbol: "NVDA").data, "NVDA261113P00215000")

    %i[volume bid open_interest implied_volatility last_trade_at].each { |field| assert_nil put[field], field }
    assert_equal BigDecimal("7.19"), put[:last_price]
  end

  test "a measured zero stays zero while a missing bid is nil (RIVN)" do
    stub_request(:get, RIVN_URL).with(query: hash_including({})).to_return(status: 200, body: sample("RIVN"))

    data = @provider.fetch_option_chain(symbol: "RIVN").data
    zero_bid = data[:rows].find { |r| r[:bid] == 0 }
    missing_bid = data[:rows].find { |r| r[:contract_symbol] == "RIVN261113C00023000" }

    assert zero_bid, "fixture has a contract quoted with a real 0 bid"
    assert_kind_of BigDecimal, zero_bid[:bid]
    assert_nil missing_bid[:bid]
  end

  test "requests a specific expiration by its UTC epoch and sends the crumb" do
    stub = stub_request(:get, CHAIN_URL).with(query: { "crumb" => "crumb", "date" => "1794528000" }).to_return(status: 200, body: sample("NVDA"))

    assert @provider.fetch_option_chain(symbol: "NVDA", expiration: Date.new(2026, 11, 13)).success?
    assert_requested stub
  end

  test "a 429 is a typed rate limit error and is requested exactly once (no 5x retry path)" do
    stub = stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 429, body: "Too Many Requests")

    response = @provider.fetch_option_chain(symbol: "NVDA")

    assert_not response.success?
    assert_kind_of Provider::YahooFinance::RateLimitError, response.error
    assert_requested stub, times: 1
  end

  test "a timeout is attempted once, not retried with the default 5x policy" do
    stub = stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_timeout

    response = @provider.fetch_option_chain(symbol: "NVDA")

    assert_not response.success?
    assert_requested stub, times: 1
  end

  test "a too-many-requests code in a 200 body is a rate limit error" do
    body = { "finance" => { "result" => nil, "error" => { "code" => "Too Many Requests", "description" => "Too Many Requests" } } }.to_json
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: body)

    assert_kind_of Provider::YahooFinance::RateLimitError, @provider.fetch_option_chain(symbol: "NVDA").error
  end

  test "a numeric 429 in optionChain.error on HTTP 200 is a typed rate limit with one request" do
    stub = stub_request(:get, CHAIN_URL).with(query: hash_including({}))
      .to_return(status: 200, body: error_body({ "code" => 429, "description" => "request limited" }))

    response = @provider.fetch_option_chain(symbol: "NVDA")

    assert_not response.success?
    assert_kind_of Provider::YahooFinance::RateLimitError, response.error
    assert_requested stub, times: 1
  end

  test "a string 429 in finance.error on HTTP 200 is a typed rate limit with one request" do
    body = { "finance" => { "result" => nil, "error" => { "code" => "429", "description" => "request limited" } } }.to_json
    stub = stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: body)

    response = @provider.fetch_option_chain(symbol: "NVDA")

    assert_not response.success?
    assert_kind_of Provider::YahooFinance::RateLimitError, response.error
    assert_requested stub, times: 1
  end

  test "a 429 while fetching the cookie is a rate limit error and never reaches the chain endpoint" do
    provider = Provider::YahooFinance.new
    provider.stubs(:throttle_request)
    stub_request(:get, "https://fc.yahoo.com").to_return(status: 429, body: "Too Many Requests")
    chain = stub_request(:get, CHAIN_URL).with(query: hash_including({}))

    response = provider.fetch_option_chain(symbol: "NVDA")

    assert_kind_of Provider::YahooFinance::RateLimitError, response.error
    assert_not_requested chain
  end

  test "a 429 while fetching the crumb is a rate limit error" do
    provider = Provider::YahooFinance.new
    provider.stubs(:throttle_request)
    stub_request(:get, "https://fc.yahoo.com").to_return(status: 404, headers: { "Set-Cookie" => "A3=d=abc; Max-Age=3600; Path=/" })
    stub_request(:get, "https://query1.finance.yahoo.com/v1/test/getcrumb").to_return(status: 429, body: "Too Many Requests")

    assert_kind_of Provider::YahooFinance::RateLimitError, provider.fetch_option_chain(symbol: "NVDA").error
  end

  test "a 429 on the retry after a crumb refresh is still a rate limit and is not retried" do
    @provider.expects(:clear_crumb_cache).once
    stub = stub_request(:get, CHAIN_URL).with(query: hash_including({}))
                                        .to_return({ status: 401, body: "{}" }, { status: 429, body: "Too Many Requests" })

    response = @provider.fetch_option_chain(symbol: "NVDA")

    assert_kind_of Provider::YahooFinance::RateLimitError, response.error
    assert_requested stub, times: 2
  end

  test "a 401 refreshes the crumb exactly once and retries" do
    @provider.expects(:clear_crumb_cache).once
    @provider.expects(:fetch_cookie_and_crumb).twice.returns([ "old", "stale" ], [ "new", "fresh" ])
    stub_request(:get, CHAIN_URL).with(query: hash_including("crumb" => "stale")).to_return(status: 401, body: { "finance" => { "error" => { "code" => "Unauthorized" } } }.to_json)
    stub_request(:get, CHAIN_URL).with(query: hash_including("crumb" => "fresh")).to_return(status: 200, body: sample("NVDA"))

    assert @provider.fetch_option_chain(symbol: "NVDA").success?
  end

  test "a second 401 gives up with an authentication error after one refresh" do
    @provider.expects(:clear_crumb_cache).once
    stub = stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 401, body: "{}")

    response = @provider.fetch_option_chain(symbol: "NVDA")

    assert_kind_of Provider::YahooFinance::AuthenticationError, response.error
    assert_requested stub, times: 2
  end

  test "an unauthorized error inside a 200 body also triggers the single refresh" do
    @provider.expects(:clear_crumb_cache).once
    unauthorized = { "finance" => { "result" => nil, "error" => { "code" => "Unauthorized" } } }.to_json
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return({ status: 200, body: unauthorized }, { status: 200, body: sample("NVDA") })

    assert @provider.fetch_option_chain(symbol: "NVDA").success?
  end

  test "an empty chain is an error, not an empty success" do
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: { "optionChain" => { "result" => [], "error" => nil } }.to_json)

    response = @provider.fetch_option_chain(symbol: "NVDA")

    assert_not response.success?
    assert_match(/No option chain/, response.error.message)
  end

  test "unparseable JSON is a provider error" do
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: "<html>")

    assert_not @provider.fetch_option_chain(symbol: "NVDA").success?
  end

  def error_body(error) = { "optionChain" => { "result" => nil, "error" => error } }.to_json

  test "an optionChain.error object is an error response carrying Yahoo's description" do
    stub_request(:get, CHAIN_URL).with(query: hash_including({}))
      .to_return(status: 200, body: error_body({ "code" => "Not Found", "description" => "No data found, symbol may be delisted" }))

    response = @provider.fetch_option_chain(symbol: "NVDA")

    assert_not response.success?
    assert_match(/No data found/, response.error.message)
  end

  test "a finance.error that is not an auth failure is an error response without a crumb refresh" do
    @provider.expects(:clear_crumb_cache).never
    stub_request(:get, CHAIN_URL).with(query: hash_including({}))
      .to_return(status: 200, body: { "finance" => { "result" => nil, "error" => { "code" => "Bad Request", "description" => "Invalid date" } } }.to_json)

    response = @provider.fetch_option_chain(symbol: "NVDA")

    assert_not response.success?
    assert_match(/Invalid date/, response.error.message)
  end

  test "an empty options array or a chain with no contracts is an error, not an empty success" do
    body = JSON.parse(sample("NVDA"))

    no_options = body.deep_dup.tap { |b| b["optionChain"]["result"][0]["options"] = [] }
    no_contracts = body.deep_dup.tap { |b| b["optionChain"]["result"][0]["options"][0].merge!("calls" => [], "puts" => []) }

    [ no_options, no_contracts ].each do |payload|
      stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: payload.to_json)
      response = @provider.fetch_option_chain(symbol: "NVDA")

      assert_not response.success?
      assert_nil response.data
    end
  end

  test "underlying previous close and quote time come from result.quote" do
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: sample("NVDA"))

    data = @provider.fetch_option_chain(symbol: "NVDA").data

    assert_equal BigDecimal("221.3"), data[:underlying_prev_close]
    assert_kind_of BigDecimal, data[:underlying_prev_close]
    assert_equal Time.at(1792094400).utc, data[:quote_time]
  end

  test "a missing previous close or quote time is nil, not zero or now" do
    body = JSON.parse(sample("NVDA"))
    body["optionChain"]["result"][0]["quote"].delete("regularMarketPreviousClose")
    body["optionChain"]["result"][0]["quote"]["regularMarketTime"] = "soon"
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: body.to_json)

    data = @provider.fetch_option_chain(symbol: "NVDA").data

    assert_nil data[:underlying_prev_close]
    assert_nil data[:quote_time]
  end

  test "bid 0 with ask 0 is a missing market (nil), while a lone zero bid stays a real zero" do
    body = JSON.parse(sample("NVDA"))
    puts_list = body.dig("optionChain", "result", 0, "options", 0, "puts")
    puts_list[0].merge!("bid" => 0, "ask" => 0)
    puts_list[1].merge!("bid" => 0, "ask" => 0.05)
    puts_list[2].merge!("bid" => 0.0, "ask" => 0.0, "lastPrice" => 0.02)
    symbols = puts_list.first(3).map { |c| c["contractSymbol"] }
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: body.to_json)

    data = @provider.fetch_option_chain(symbol: "NVDA").data

    both_zero, lone_zero, both_zero_with_last = symbols.map { |s| row(data, s) }
    assert_nil both_zero[:bid]
    assert_nil both_zero[:ask]
    assert_equal 0, lone_zero[:bid]
    assert_kind_of BigDecimal, lone_zero[:bid]
    assert_equal BigDecimal("0.05"), lone_zero[:ask]
    assert_nil both_zero_with_last[:bid]
    assert_nil both_zero_with_last[:ask]
    assert_equal BigDecimal("0.02"), both_zero_with_last[:last_price], "a missing market keeps its last print"
  end

  test "a row that lacks bid, ask and last keeps all three nil" do
    body = JSON.parse(sample("NVDA"))
    contract = body.dig("optionChain", "result", 0, "options", 0, "calls", 0)
    contract.except!("bid", "ask", "lastPrice")
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: body.to_json)

    parsed = row(@provider.fetch_option_chain(symbol: "NVDA").data, contract["contractSymbol"])

    assert_nil parsed[:bid]
    assert_nil parsed[:ask]
    assert_nil parsed[:last_price]
  end

  test "prices and changes are BigDecimal rounded to 2 decimals at ingestion, going through the float's shortest string" do
    body = JSON.parse(sample("NVDA"))
    contract = body.dig("optionChain", "result", 0, "options", 0, "puts", 0)
    contract.merge!("bid" => 1.2349, "ask" => 1.2351, "lastPrice" => 0.30000000000000004, "change" => -0.005, "percentChange" => 12.3456789)
    body["optionChain"]["result"][0]["quote"]["regularMarketPrice"] = 217.2349
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: body.to_json)

    data = @provider.fetch_option_chain(symbol: "NVDA").data
    parsed = row(data, contract["contractSymbol"])

    assert_equal BigDecimal("1.23"), parsed[:bid]
    assert_equal BigDecimal("1.24"), parsed[:ask]
    assert_equal BigDecimal("0.3"), parsed[:last_price]
    assert_equal BigDecimal("-0.01"), parsed[:change]
    assert_equal BigDecimal("217.23"), data[:underlying_price]
    assert_equal BigDecimal("12.3456789"), parsed[:percent_change], "percentages are ratios of the source, not prices"
  end

  test "contract_size is carried per row and nil when Yahoo omits it" do
    body = JSON.parse(sample("NVDA"))
    calls = body.dig("optionChain", "result", 0, "options", 0, "calls")
    calls[1]["contractSize"] = "MINI"
    calls[2].delete("contractSize")
    stub_request(:get, CHAIN_URL).with(query: hash_including({})).to_return(status: 200, body: body.to_json)

    data = @provider.fetch_option_chain(symbol: "NVDA").data

    assert_equal "REGULAR", row(data, calls[0]["contractSymbol"])[:contract_size]
    assert_equal "MINI", row(data, calls[1]["contractSymbol"])[:contract_size]
    assert_nil row(data, calls[2]["contractSymbol"])[:contract_size]
  end

  test "expiration dates are UTC dates and the requested date is a UTC epoch even when the host TZ is America/Chicago" do
    previous = ENV["TZ"]
    ENV["TZ"] = "America/Chicago"
    # 1794528000 is 2026-11-13 00:00 UTC, which is still Nov 12 19:00 in Chicago.
    stub = stub_request(:get, CHAIN_URL).with(query: { "crumb" => "crumb", "date" => "1794528000" }).to_return(status: 200, body: sample("NVDA"))

    data = @provider.fetch_option_chain(symbol: "NVDA", expiration: Date.new(2026, 11, 13)).data

    assert_requested stub
    assert_includes data[:expirations], Date.new(2026, 11, 13)
    assert_equal [ Date.new(2026, 11, 13) ], data[:rows].map { |r| r[:expiration] }.uniq
    assert_equal Date.new(2026, 11, 13), row(data, "NVDA261113P00215000")[:expiration]
  ensure
    ENV["TZ"] = previous
  end
end
