require "test_helper"

class OptionQuote::RefresherTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 10, 15)
  NOV13 = Date.new(2026, 11, 13)

  # Stands in for Provider::YahooFinance. Chains are the real NVDA sample's
  # shape (parsed by the real parser) re-labelled for the requested symbol and
  # expiration, so nothing here touches the network.
  class FakeProvider
    attr_reader :calls
    attr_accessor :spot, :expirations, :overrides, :quote_time, :prev_close, :patch

    def initialize(sample)
      @sample = sample
      @calls = []
      @spot = BigDecimal("217.23")
      @expirations = [ Date.new(2026, 10, 16), Date.new(2026, 10, 23), Date.new(2026, 11, 13), Date.new(2026, 11, 20), Date.new(2026, 12, 18) ]
      @overrides = {}
      # 10:55 ET on TODAY, inside the session the tests travel to (11:00 ET).
      @quote_time = Time.utc(2026, 10, 15, 14, 55)
      @prev_close = BigDecimal("221.3")
      @patch = nil
    end

    def fetch_option_chain(symbol:, expiration: nil)
      @calls << [ symbol, expiration ]
      handler = @overrides[[ symbol, expiration ]] || @overrides[symbol]
      return handler.respond_to?(:call) ? handler.call : handler if handler

      expiry = expiration || @expirations.first
      rows = @sample[:rows].map do |row|
        built = row.merge(
          underlying: symbol, expiration: expiry,
          contract_symbol: "#{symbol}#{expiry.strftime('%y%m%d')}#{row[:option_type][0]}#{format('%08d', (row[:strike] * 1000).to_i)}"
        )
        @patch ? @patch.call(built) : built
      end
      Provider::Response.new(success?: true, data: { underlying_price: @spot, underlying_prev_close: @prev_close, quote_time: @quote_time, expirations: @expirations, rows: rows }, error: nil)
    end
  end

  def error_response(message, klass = Provider::YahooFinance::Error)
    Provider::Response.new(success?: false, data: nil, error: klass.new(message))
  end

  setup do
    travel_to Time.utc(2026, 10, 15, 15, 0)
    Holding.delete_all
    AccountProvider.where(provider_type: "SnaptradeAccount").delete_all
    SnaptradeAccount.delete_all

    body = JSON.parse(File.read(file_fixture("yahoo-options-NVDA.json")))
    sample = Provider::YahooFinance.new.send(:parse_option_chain, body.dig("optionChain", "result", 0))
    @provider = FakeProvider.new(sample)
    @rolled = []
    @session_mark = ->(attrs) { @rolled << attrs; BigDecimal("1.5") }
    @refresher = OptionQuote::Refresher.new(provider: @provider, pause: 0, session_mark_fn: @session_mark)
  end

  def memory_cache!
    ActiveSupport::Cache::MemoryStore.new.tap { |cache| Rails.stubs(:cache).returns(cache) }
  end

  def stored(symbol = "NVDA261113P00215000") = OptionQuote.find_by!(contract_symbol: symbol)

  def quote_attrs(overrides = {})
    attrs = { contract_symbol: "NVDA261113P00215000", underlying: "NVDA", option_type: "PUT", strike: 215, expiration: NOV13, fetched_at: 3.hours.ago }.merge(overrides)
    attrs[:quote_time] ||= Time.utc(2026, 10, 15, 14, 0) if attrs[:session_date].present? && !attrs.key?(:quote_time)
    attrs
  end

  teardown { travel_back }

  def contract(symbol, expiry, units: "-1", type: "PUT", strike: "215")
    { "instrument" => { "symbol" => symbol, "option_type" => type, "expiration_date" => expiry.to_s, "strike_price" => strike, "multiplier" => "100" },
      "units" => units, "price" => "3.25", "cost_basis" => "2.14", "currency" => { "code" => "USD" } }
  end

  def broker_account(family, contracts)
    suffix = SecureRandom.hex(3)
    account = family.accounts.create!(name: "Broker #{suffix}", balance: 1000, cash_balance: 0, currency: "USD", accountable: Investment.new(subtype: "brokerage"))
    item = SnaptradeItem.create!(family: family, name: "Item #{suffix}", client_id: "c-#{suffix}", consumer_key: "k-#{suffix}", status: "good")
    provider = SnaptradeAccount.create!(snaptrade_item: item, snaptrade_account_id: "sa-#{suffix}", name: "Broker #{suffix}", currency: "USD", current_balance: 1000, last_holdings_sync: Time.current, raw_options_payload: contracts)
    AccountProvider.create!(account: account, provider: provider)
    account
  end

  def hold(account, ticker, qty)
    security = Security.find_or_create_by!(ticker: ticker) { |s| s.name = ticker }
    Holding.create!(account: account, security: security, date: Date.current, qty: qty, price: 10, amount: qty * 10, currency: "USD")
  end

  def nvda_put = contract("NVDA  261113P00215000", NOV13)

  # --- universe ------------------------------------------------------------

  test "universe is every open broker contract across all linked accounts, regardless of family" do
    broker_account(families(:dylan_family), [ nvda_put ])
    broker_account(families(:empty), [ contract("AAPL  261218C00250000", Date.new(2026, 12, 18), units: "2", type: "CALL", strike: "250") ])

    universe = OptionQuote::Refresher.universe(today: TODAY)

    assert_equal [ [ "AAPL", Date.new(2026, 12, 18) ], [ "NVDA", NOV13 ] ], universe.broker_pairs.sort
    assert_equal Set["NVDA261113P00215000", "AAPL261218C00250000"], universe.held_symbols
  end

  test "universe dedupes underlying+expiration pairs and skips expired and closed contracts" do
    broker_account(families(:dylan_family), [
      nvda_put,
      contract("NVDA  261113C00230000", NOV13, type: "CALL", strike: "230"),
      contract("OLD   261001P00100000", Date.new(2026, 10, 1)),
      contract("ZERO  261113P00100000", NOV13, units: "0"),
      contract("TODAY 261015P00100000", TODAY)
    ])
    broker_account(families(:empty), [ nvda_put ])

    pairs = OptionQuote::Refresher.universe(today: TODAY).broker_pairs

    assert_equal [ [ "NVDA", NOV13 ], [ "TODAY", TODAY ] ], pairs.sort
  end

  test "universe ignores provider accounts that are not linked to a Sure account" do
    SnaptradeAccount.create!(snaptrade_item: SnaptradeItem.create!(family: families(:empty), name: "Orphan", client_id: "o", consumer_key: "o", status: "good"),
                             snaptrade_account_id: "orphan", name: "Orphan", currency: "USD", current_balance: 0, raw_options_payload: [ nvda_put ])

    assert_empty OptionQuote::Refresher.universe(today: TODAY).broker_pairs
  end

  test "universe makes no provider or network calls" do
    broker_account(families(:dylan_family), [ nvda_put ])

    OptionQuote::Refresher.universe(today: TODAY)

    assert_empty @provider.calls
  end

  test "idea universe lists underlyings with 100+ shares in one account first, then other held securities, capped at 40" do
    account = broker_account(families(:dylan_family), [])
    hold(account, "SMALL", 5)
    hold(account, "BIGCO", 150)
    hold(account, "SPLIT", 60)
    hold(broker_account(families(:empty), []), "SPLIT", 60) # 60 + 60 across accounts is not a coverable lot

    ideas = OptionQuote::Refresher.universe(today: TODAY).idea_underlyings

    assert_equal "BIGCO", ideas.first
    assert_equal %w[SMALL SPLIT], ideas.drop(1).sort

    45.times { |i| hold(account, "T#{('A'.ord + i / 26).chr}#{('A'.ord + i % 26).chr}", 100) }
    assert_equal OptionQuote::Refresher::MAX_IDEA_UNDERLYINGS, OptionQuote::Refresher.universe(today: TODAY).idea_underlyings.size
    assert_equal 40, OptionQuote::Refresher::MAX_IDEA_UNDERLYINGS
  end

  # --- refreshing ----------------------------------------------------------

  test "upserts by contract_symbol so a second run updates instead of duplicating" do
    broker_account(families(:dylan_family), [ nvda_put ])

    @refresher.refresh_all
    first = OptionQuote.find_by!(contract_symbol: "NVDA261113P00215000")
    count = OptionQuote.count

    travel 30.minutes
    @refresher.refresh_all

    assert_equal count, OptionQuote.count
    assert_operator OptionQuote.find(first.id).fetched_at, :>, first.fetched_at
    assert_equal "PUT", first.option_type
    assert_equal BigDecimal("217.23"), first.underlying_price
    assert_equal "yahoo_finance", first.source
  end

  test "a held contract's quote carries exact figures from the chain" do
    broker_account(families(:dylan_family), [ nvda_put ])

    @refresher.refresh_all

    quote = OptionQuote.find_by!(contract_symbol: "NVDA261113P00215000")
    assert_equal NOV13, quote.expiration
    assert_equal BigDecimal("215"), quote.strike
    assert_equal "NVDA", quote.underlying
    assert_equal Time.current.to_i, quote.fetched_at.to_i
  end

  test "a failed request leaves the previous good row untouched" do
    broker_account(families(:dylan_family), [ nvda_put ])
    old = 3.hours.ago
    OptionQuote.create!(contract_symbol: "NVDA261113P00215000", underlying: "NVDA", option_type: "PUT", strike: 215, expiration: NOV13,
                        last_price: 7.19, fetched_at: old)
    @provider.overrides[[ "NVDA", NOV13 ]] = error_response("boom")

    result = @refresher.refresh_all

    assert_equal 1, result.failed
    assert_equal 0, result.refreshed
    quote = OptionQuote.find_by!(contract_symbol: "NVDA261113P00215000")
    assert_equal old.to_i, quote.fetched_at.to_i
    assert_equal BigDecimal("7.19"), quote.last_price
  end

  test "an exception from one item is contained and the next item still runs" do
    broker_account(families(:dylan_family), [ nvda_put, contract("AAPL  261113P00200000", NOV13, strike: "200") ])
    @provider.overrides["AAPL"] = -> { raise "kaput" }

    result = @refresher.refresh_all

    assert_equal 1, result.failed
    assert_equal 1, result.refreshed
    assert OptionQuote.exists?(contract_symbol: "NVDA261113P00215000")
  end

  test "the first 429 stops the whole run and keeps what was cached" do
    broker_account(families(:dylan_family), [ contract("AAA   261113P00100000", NOV13), contract("BBB   261113P00100000", NOV13), contract("CCC   261113P00100000", NOV13) ])
    @provider.overrides["BBB"] = error_response("Yahoo Finance rate limit (429)", Provider::YahooFinance::RateLimitError)

    result = @refresher.refresh_all

    assert result.skipped_for_rate_limit
    assert_equal 2, @provider.calls.size, "no request after the rate limit"
    assert_equal %w[AAA BBB], @provider.calls.map(&:first)
    assert_equal 1, result.refreshed
    assert_equal 0, result.failed
  end

  test "a rate limit still prunes and does not wipe good data" do
    broker_account(families(:dylan_family), [ nvda_put ])
    OptionQuote.create!(contract_symbol: "NVDA261113P00215000", underlying: "NVDA", option_type: "PUT", strike: 215, expiration: NOV13, last_price: 7.19, fetched_at: 1.hour.ago)
    @provider.overrides["NVDA"] = error_response("429", Provider::YahooFinance::RateLimitError)

    result = @refresher.refresh_all

    assert result.skipped_for_rate_limit
    assert_equal BigDecimal("7.19"), OptionQuote.find_by!(contract_symbol: "NVDA261113P00215000").last_price
  end

  test "the pause between requests is injectable and skipped when zero" do
    broker_account(families(:dylan_family), %w[AAA BBB CCC].map { |t| contract("#{t.ljust(6)}261113P00100000", NOV13) })

    slow = OptionQuote::Refresher.new(provider: @provider, pause: 0.25)
    slow.expects(:sleep).with(0.25).twice
    slow.refresh_all

    @refresher.expects(:sleep).never
    @refresher.refresh_all
  end

  test "the default pause is 1.5 seconds" do
    assert_equal 1.5, OptionQuote::Refresher::PAUSE_BETWEEN_REQUESTS
  end

  test "two accounts holding the same contract cost one request" do
    broker_account(families(:dylan_family), [ nvda_put ])
    broker_account(families(:empty), [ nvda_put ])

    @refresher.refresh_all

    assert_equal [ [ "NVDA", NOV13 ] ], @provider.calls
  end

  test "a failed pair is not retried for an hour" do
    cache = ActiveSupport::Cache::MemoryStore.new
    Rails.stubs(:cache).returns(cache)
    broker_account(families(:dylan_family), [ nvda_put ])
    @provider.overrides["NVDA"] = error_response("boom")

    @refresher.refresh_all
    assert_equal 1, @provider.calls.size

    travel 30.minutes
    result = @refresher.refresh_all
    assert_equal 1, @provider.calls.size, "still backed off"
    assert_equal 1, result.backed_off

    travel 31.minutes
    @refresher.refresh_all
    assert_equal 2, @provider.calls.size
  end

  test "only strikes within 30% of spot are stored, except contracts actually held" do
    broker_account(families(:dylan_family), [ contract("NVDA  261113P00085000", NOV13, strike: "85") ])

    @refresher.refresh_all

    strikes = OptionQuote.where(underlying: "NVDA").pluck(:strike)
    spot = BigDecimal("217.23")
    outside = strikes.reject { |s| s.between?(spot * BigDecimal("0.7"), spot * BigDecimal("1.3")) }
    assert_equal [ BigDecimal("85") ], outside, "only the held far-OTM put is kept outside the band"
    assert strikes.size > 10
    assert_includes strikes, BigDecimal("215")
  end

  test "without a spot price only the held contracts are stored" do
    broker_account(families(:dylan_family), [ nvda_put ])
    @provider.spot = nil

    @refresher.refresh_all

    assert_equal [ "NVDA261113P00215000" ], OptionQuote.pluck(:contract_symbol)
    assert_nil OptionQuote.first.underlying_price
  end

  test "rows for a different expiration than the one requested are not stored" do
    broker_account(families(:dylan_family), [ nvda_put ])
    rows = @provider.fetch_option_chain(symbol: "NVDA", expiration: Date.new(2026, 10, 16)).data
    @provider.calls.clear
    @provider.overrides["NVDA"] = Provider::Response.new(success?: true, data: rows, error: nil)

    @refresher.refresh_all

    assert_equal 0, OptionQuote.count
  end

  test "idea scan: held underlyings get the two expirations nearest the 21-45 DTE window" do
    hold(broker_account(families(:dylan_family), []), "NVDA", 200)

    result = @refresher.refresh_all

    assert_equal [ [ "NVDA", nil ], [ "NVDA", NOV13 ], [ "NVDA", Date.new(2026, 11, 20) ] ], @provider.calls
    assert_equal 2, OptionQuote.where(underlying: "NVDA").distinct.count(:expiration)
    assert_equal 3, result.requests
  end

  test "idea scan reuses an expiration list already fetched for a broker contract" do
    account = broker_account(families(:dylan_family), [ nvda_put ])
    hold(account, "NVDA", 100)

    @refresher.refresh_all

    assert_equal [ [ "NVDA", NOV13 ], [ "NVDA", Date.new(2026, 11, 20) ] ], @provider.calls
  end

  test "an idea discovery failure is counted and does not stop later underlyings" do
    account = broker_account(families(:dylan_family), [])
    hold(account, "AAA", 100)
    hold(account, "BBB", 100)
    @provider.overrides["AAA"] = error_response("no chain")

    result = @refresher.refresh_all

    assert_equal 1, result.failed
    assert OptionQuote.exists?(underlying: "BBB")
  end

  # --- pruning -------------------------------------------------------------

  test "a dotted class-share underlying is never requested (Yahoo spells it differently)" do
    broker_account(families(:dylan_family), [ contract("BRK.B 261113P00400000", NOV13, strike: "400") ])

    @refresher.refresh_all

    assert_empty @provider.calls
  end

  # --- v2: budgets, priority, rotation -------------------------------------------

  def held_tickers(count) = Array.new(count) { |i| "H#{('A'.ord + i / 26).chr}#{('A'.ord + i % 26).chr}" }

  def hold_pairs(tickers) = broker_account(families(:dylan_family), tickers.map { |t| contract("#{t.ljust(6)}261113P00100000", NOV13) })

  test "the held budget caps held requests at 40 by default and the cap is enforced per call" do
    hold_pairs(held_tickers(45))

    result = @refresher.refresh_all

    assert_equal 40, @provider.calls.size
    assert_equal 40, result.requests

    @provider.calls.clear
    @refresher.refresh_all(held_budget: 3)
    assert_equal 3, @provider.calls.size
  end

  test "the idea budget caps idea requests at 20 by default" do
    account = broker_account(families(:dylan_family), [])
    held_tickers(30).each { |ticker| hold(account, ticker, 100) }

    result = @refresher.refresh_all

    assert_equal 20, result.requests
    assert_equal 20, @provider.calls.size
  end

  test "held and idea budgets are separate: held pairs run first and never eat the idea budget" do
    account = hold_pairs(%w[AAA BBB])
    %w[XXX YYY ZZZ].each { |ticker| hold(account, ticker, 100) }

    result = @refresher.refresh_all(held_budget: 1, idea_budget: 2)

    assert_equal 3, result.requests
    assert_equal "AAA", @provider.calls.first.first
    assert_equal [ [ "AAA", NOV13 ] ], @provider.calls.first(1)
    assert_equal 2, @provider.calls.drop(1).size
    assert @provider.calls.drop(1).none? { |symbol, _| %w[AAA BBB].include?(symbol) }
  end

  test "an exhausted idea budget cannot starve held pairs, which are always fetched first" do
    account = hold_pairs(%w[AAA BBB CCC])
    hold(account, "XXX", 100)

    @refresher.refresh_all(held_budget: 40, idea_budget: 0)

    assert_equal [ [ "AAA", NOV13 ], [ "BBB", NOV13 ], [ "CCC", NOV13 ] ], @provider.calls.sort
  end

  test "held pairs are fetched stalest first" do
    hold_pairs(%w[AAA BBB CCC])
    OptionQuote.create!(quote_attrs(contract_symbol: "AAA261113P00100000", underlying: "AAA", strike: 100, fetched_at: 10.minutes.ago))
    OptionQuote.create!(quote_attrs(contract_symbol: "BBB261113P00100000", underlying: "BBB", strike: 100, fetched_at: 5.hours.ago))

    @refresher.refresh_all(held_budget: 2)

    assert_equal %w[CCC BBB], @provider.calls.map(&:first)
  end

  test "idea underlyings rotate stalest first so a capped run moves through the whole set" do
    account = broker_account(families(:dylan_family), [])
    %w[AAA BBB CCC].each { |ticker| hold(account, ticker, 100) }
    OptionQuote.create!(quote_attrs(contract_symbol: "AAA261113P00100000", underlying: "AAA", strike: 100, fetched_at: 10.minutes.ago))
    OptionQuote.create!(quote_attrs(contract_symbol: "BBB261113P00100000", underlying: "BBB", strike: 100, fetched_at: 5.hours.ago))

    @refresher.refresh_all(idea_budget: 4)

    assert_equal %w[CCC BBB], @provider.calls.map(&:first).uniq, "never-fetched first, then the oldest; AAA is the freshest and waits"
  end

  test "idea scan: held underlyings get the two expirations nearest the window, discovery counted against the idea budget" do
    hold(broker_account(families(:dylan_family), []), "NVDA", 200)

    result = @refresher.refresh_all(idea_budget: 3)

    assert_equal [ [ "NVDA", nil ], [ "NVDA", NOV13 ], [ "NVDA", Date.new(2026, 11, 20) ] ], @provider.calls
    assert_equal 3, result.requests
  end

  test "expirationDates are cached per underlying for the day" do
    memory_cache!
    hold(broker_account(families(:dylan_family), []), "NVDA", 200)

    @refresher.refresh_all
    assert_equal 1, @provider.calls.count { |_, expiration| expiration.nil? }

    @provider.calls.clear
    travel 30.minutes
    @refresher.refresh_all
    assert_equal [ [ "NVDA", NOV13 ], [ "NVDA", Date.new(2026, 11, 20) ] ], @provider.calls, "no second discovery request the same day"

    @provider.calls.clear
    travel 1.day
    @refresher.refresh_all
    assert_equal 1, @provider.calls.count { |_, expiration| expiration.nil? }, "a new day discovers again"
  end

  test "only plain 1-5 letter tickers are requested" do
    account = broker_account(families(:dylan_family), [ contract("GME1  261113C00031000", NOV13, type: "CALL", strike: "31"), contract("ABCDEF261113P00100000", NOV13) ])
    hold(account, "BRK.B", 100)

    @refresher.refresh_all

    assert_empty @provider.calls
  end

  # --- v2: strike filter ---------------------------------------------------------

  test "held contracts are stored whatever their strike, the +/-30% band only trims the rest" do
    broker_account(families(:dylan_family), [ contract("NVDA  261113P00085000", NOV13, strike: "85"), contract("NVDA  261113C00350000", NOV13, type: "CALL", strike: "350") ])

    @refresher.refresh_all

    strikes = OptionQuote.where(underlying: "NVDA").pluck(:strike)
    assert_includes strikes, BigDecimal("85")
    assert_includes strikes, BigDecimal("350")
    spot = BigDecimal("217.23")
    assert_equal [ BigDecimal("85"), BigDecimal("350") ], strikes.reject { |strike| strike.between?(spot * BigDecimal("0.7"), spot * BigDecimal("1.3")) }.sort
  end

  test "an idea-only chain is filtered to +/-30% of spot" do
    hold(broker_account(families(:dylan_family), []), "NVDA", 200)

    @refresher.refresh_all

    spot = BigDecimal("217.23")
    strikes = OptionQuote.where(underlying: "NVDA").pluck(:strike)
    assert strikes.size > 10
    assert strikes.all? { |strike| strike.between?(spot * BigDecimal("0.7"), spot * BigDecimal("1.3")) }
  end

  # --- v2: stored fields ----------------------------------------------------------

  test "stores the quote's as-of, trading date, underlying previous close and contract size" do
    broker_account(families(:dylan_family), [ nvda_put ])

    @refresher.refresh_all

    quote = stored
    assert_equal Time.utc(2026, 10, 15, 14, 55), quote.quote_time
    assert_equal TODAY, quote.session_date
    assert_equal BigDecimal("221.3"), quote.underlying_prev_close
    assert_equal BigDecimal("217.23"), quote.underlying_price
    assert_equal "REGULAR", quote.contract_size
    assert_nil quote.prev_session_mark
    assert_nil quote.prev_session_date
  end

  test "session_date is the New York date of the quote time, not the UTC date" do
    broker_account(families(:dylan_family), [ nvda_put ])
    @provider.quote_time = Time.utc(2026, 10, 16, 0, 30) # 20:30 ET on Oct 15 (after-hours stamp)

    @refresher.refresh_all

    assert_equal TODAY, stored.session_date
  end

  test "an unknown quote time fails closed without inserting a row or starting a cooldown" do
    cache = memory_cache!
    broker_account(families(:dylan_family), [ nvda_put ])
    @provider.quote_time = nil

    result = @refresher.refresh_all

    assert_equal 1, result.failed
    assert_equal 0, result.refreshed
    assert_empty OptionQuote.where(contract_symbol: "NVDA261113P00215000")
    assert cache.exist?("option_quotes_refresher:backoff:NVDA:#{NOV13}")
    assert_not cache.exist?(OptionQuote::Refresher::COOLDOWN_KEY)
  end

  test "an invalid quote time fails closed without touching a current stored row" do
    cache = memory_cache!
    broker_account(families(:dylan_family), [ nvda_put ])
    OptionQuote.create!(quote_attrs(bid: "7.05", ask: "7.20", last_price: "7.19", session_date: TODAY,
                                    quote_time: Time.utc(2026, 10, 15, 14, 0), last_trade_at: Time.utc(2026, 10, 15, 14, 0)))
    before = stored.attributes.slice("bid", "ask", "last_price", "session_date", "quote_time", "fetched_at", "last_trade_at")
    @provider.quote_time = "not-a-timestamp"

    result = @refresher.refresh_all

    assert_equal 1, result.failed
    assert_equal 0, result.refreshed
    assert_equal before, stored.attributes.slice("bid", "ask", "last_price", "session_date", "quote_time", "fetched_at", "last_trade_at")
    assert cache.exist?("option_quotes_refresher:backoff:NVDA:#{NOV13}")
    assert_not cache.exist?(OptionQuote::Refresher::COOLDOWN_KEY)
  end

  test "a non-regular contract size from the provider is stored as given" do
    broker_account(families(:dylan_family), [ nvda_put ])
    @provider.patch = ->(row) { row.merge(contract_size: "MINI") }

    @refresher.refresh_all

    assert_equal "MINI", stored.contract_size
  end

  # --- v2: field-wise upsert -------------------------------------------------------

  test "within a session a nil from the provider never replaces a stored value, other fields still update" do
    broker_account(families(:dylan_family), [ nvda_put ])
    OptionQuote.create!(quote_attrs(bid: "7.05", ask: "7.20", last_price: "7.19", implied_volatility: "0.33", volume: 5, open_interest: 99,
                                    session_date: TODAY, quote_time: Time.utc(2026, 10, 15, 14, 0), last_trade_at: Time.utc(2026, 10, 15, 14, 0)))
    @provider.patch = ->(row) { row.merge(bid: nil, ask: nil, last_price: nil, implied_volatility: nil, open_interest: nil, last_trade_at: nil, volume: 11) }

    @refresher.refresh_all

    quote = stored
    assert_equal BigDecimal("7.05"), quote.bid
    assert_equal BigDecimal("7.2"), quote.ask
    assert_equal BigDecimal("7.19"), quote.last_price
    assert_equal BigDecimal("0.33"), quote.implied_volatility
    assert_equal 99, quote.open_interest
    assert_equal Time.utc(2026, 10, 15, 14, 0), quote.last_trade_at
    assert_equal 11, quote.volume
    assert_equal Time.current.to_i, quote.fetched_at.to_i
    assert_equal Time.utc(2026, 10, 15, 14, 55), quote.quote_time
  end

  test "a real zero replaces a stored value and a provider value replaces a nil" do
    broker_account(families(:dylan_family), [ nvda_put ])
    OptionQuote.create!(quote_attrs(bid: "7.05", ask: nil, session_date: TODAY))
    @provider.patch = ->(row) { row.merge(bid: BigDecimal("0"), ask: BigDecimal("0.05")) }

    @refresher.refresh_all

    assert_equal 0, stored.bid
    assert_equal BigDecimal("0.05"), stored.ask
  end

  test "underlying fields are also field-wise within a session" do
    broker_account(families(:dylan_family), [ nvda_put ])
    OptionQuote.create!(quote_attrs(underlying_price: "217.23", underlying_prev_close: "221.30", session_date: TODAY))
    @provider.spot = nil
    @provider.prev_close = nil

    @refresher.refresh_all

    assert_equal BigDecimal("217.23"), stored.underlying_price
    assert_equal BigDecimal("221.3"), stored.underlying_prev_close
  end

  test "a new session starts clean: a nil in the new session does replace last session's value" do
    broker_account(families(:dylan_family), [ nvda_put ])
    OptionQuote.create!(quote_attrs(bid: "7.05", ask: "7.20", session_date: TODAY - 1))
    @provider.patch = ->(row) { row.merge(bid: nil, ask: nil) }

    @refresher.refresh_all

    assert_nil stored.bid
    assert_nil stored.ask
    assert_equal TODAY, stored.session_date
  end

  test "an error response never modifies or deletes any stored row" do
    broker_account(families(:dylan_family), [ nvda_put ])
    OptionQuote.create!(quote_attrs(bid: "7.05", ask: "7.20", last_price: "7.19", session_date: TODAY - 1, prev_session_mark: "3.3", prev_session_date: TODAY - 2))
    OptionQuote.create!(quote_attrs(contract_symbol: "NVDA261113P00220000", strike: 220, bid: "9"))
    before = OptionQuote.order(:contract_symbol).map(&:attributes)
    @provider.overrides["NVDA"] = error_response("boom")

    result = @refresher.refresh_all

    assert_equal 1, result.failed
    assert_equal before, OptionQuote.order(:contract_symbol).map(&:attributes)
    assert_empty @rolled
  end

  test "an empty chain from the provider is a failure that leaves rows untouched" do
    broker_account(families(:dylan_family), [ nvda_put ])
    OptionQuote.create!(quote_attrs(bid: "7.05", session_date: TODAY - 1))
    before = OptionQuote.order(:contract_symbol).map(&:attributes)
    empty = Provider::Response.new(success?: true, data: { underlying_price: BigDecimal("217.23"), expirations: [ NOV13 ], rows: [] }, error: nil)
    @provider.overrides["NVDA"] = empty

    result = @refresher.refresh_all

    assert_equal 1, result.failed
    assert_equal 0, result.refreshed
    assert_equal before, OptionQuote.order(:contract_symbol).map(&:attributes)
  end

  # --- v2: session rollover ---------------------------------------------------------

  test "a new session rolls the old row into prev_session_mark and prev_session_date, using the injected function" do
    broker_account(families(:dylan_family), [ nvda_put ])
    last_trade = Time.utc(2026, 10, 14, 19, 59)
    OptionQuote.create!(quote_attrs(bid: "7.05", ask: "7.20", last_price: "7.19", last_trade_at: last_trade, session_date: TODAY - 1))

    @refresher.refresh_all

    assert_equal 1, @rolled.size
    attrs = @rolled.first
    assert_equal BigDecimal("7.05"), attrs[:bid]
    assert_equal BigDecimal("7.2"), attrs[:ask]
    assert_equal BigDecimal("7.19"), attrs[:last_price]
    assert_equal last_trade, attrs[:last_trade_at]
    assert_equal TODAY - 1, attrs[:session_date], "the function sees the OLD row, before it is overwritten"
    quote = stored
    assert_equal BigDecimal("1.5"), quote.prev_session_mark
    assert_equal TODAY - 1, quote.prev_session_date
    assert_equal TODAY, quote.session_date
  end

  test "the same session is never rolled twice, however often it is refreshed" do
    broker_account(families(:dylan_family), [ nvda_put ])
    OptionQuote.create!(quote_attrs(bid: "7.05", ask: "7.20", session_date: TODAY - 1))

    3.times do
      @refresher.refresh_all
      travel 30.minutes
    end

    assert_equal 1, @rolled.size
    assert_equal TODAY - 1, stored.prev_session_date
    assert_equal BigDecimal("1.5"), stored.prev_session_mark
  end

  test "the next session rolls again from that session's last figures" do
    broker_account(families(:dylan_family), [ nvda_put ])
    OptionQuote.create!(quote_attrs(session_date: TODAY - 1))
    @refresher.refresh_all
    @provider.quote_time = Time.utc(2026, 10, 16, 14, 55)
    travel_to Time.utc(2026, 10, 16, 15, 0)

    @refresher.refresh_all

    rolls = @rolled.select { |attrs| attrs[:contract_symbol] == "NVDA261113P00215000" }
    assert_equal 2, rolls.size, "once per session change"
    assert_equal [ TODAY - 1, TODAY ], rolls.map { |attrs| attrs[:session_date] }
    assert_equal TODAY, stored.prev_session_date
    assert_equal TODAY + 1, stored.session_date
  end

  test "a mark the function cannot give (nil) is stored as an unknown baseline, not as zero" do
    broker_account(families(:dylan_family), [ nvda_put ])
    OptionQuote.create!(quote_attrs(session_date: TODAY - 1, prev_session_mark: "4.0", prev_session_date: TODAY - 2))
    refresher = OptionQuote::Refresher.new(provider: @provider, pause: 0, session_mark_fn: ->(_attrs) { nil })

    refresher.refresh_all

    assert_nil stored.prev_session_mark
    assert_nil stored.prev_session_date
  end

  test "no roll for a first insert, a row without a session, or a response from an older session" do
    broker_account(families(:dylan_family), [ nvda_put, contract("NVDA  261113C00230000", NOV13, type: "CALL", strike: "230") ])
    OptionQuote.create!(quote_attrs(contract_symbol: "NVDA261113C00230000", option_type: "CALL", strike: 230, session_date: nil, prev_session_mark: "2.0", prev_session_date: TODAY - 3))

    @refresher.refresh_all
    assert_empty @rolled, "first insert and a legacy row without a session_date do not roll"
    assert_equal BigDecimal("2.0"), stored("NVDA261113C00230000").prev_session_mark

    @provider.quote_time = Time.utc(2026, 10, 14, 19, 59) # a stale response from yesterday
    travel 30.minutes
    @refresher.refresh_all

    assert_empty @rolled
    assert_equal TODAY, stored.session_date, "an older session never overwrites a newer one"
    assert_nil stored.prev_session_date
  end

  test "the default session mark function resolves Options::Mark lazily and passes only the five mark fields" do
    assert_nothing_raised { OptionQuote::Refresher.new(provider: @provider, pause: 0) }

    attrs = { bid: BigDecimal("1"), ask: BigDecimal("2"), last_price: BigDecimal("1.5"), last_trade_at: Time.utc(2026, 10, 14), session_date: TODAY - 1, fetched_at: Time.current, strike: 215 }
    expected = attrs.slice(:bid, :ask, :last_price, :last_trade_at, :session_date)

    if defined?(::Options::Mark)
      ::Options::Mark.expects(:session_mark).with(**expected).returns(BigDecimal("2.25"))
      assert_equal BigDecimal("2.25"), OptionQuote::Refresher::DEFAULT_SESSION_MARK_FN.call(attrs)
    else
      # The calc namespace lives in another branch until integration; stand one in.
      seen = []
      Object.const_set(:Options, Module.new)
      ::Options.const_set(:Mark, Module.new { define_singleton_method(:session_mark) { |**kwargs| seen << kwargs; BigDecimal("2.25") } })
      begin
        assert_equal BigDecimal("2.25"), OptionQuote::Refresher::DEFAULT_SESSION_MARK_FN.call(attrs)
        assert_equal [ expected ], seen
      ensure
        Object.send(:remove_const, :Options)
      end
    end
  end

  # --- v2: cooldown ------------------------------------------------------------------

  test "the first RateLimitError stops both phases and sets the yahoo:cooldown key for 15 minutes" do
    cache = memory_cache!
    account = hold_pairs(%w[AAA BBB CCC])
    hold(account, "XXX", 100)
    @provider.overrides["BBB"] = error_response("429", Provider::YahooFinance::RateLimitError)

    result = @refresher.refresh_all

    assert result.skipped_for_rate_limit
    assert_equal %w[AAA BBB], @provider.calls.map(&:first), "nothing after the 429, idea phase included"
    assert cache.exist?("yahoo:cooldown")
    assert_equal 0, result.failed

    travel 14.minutes
    assert cache.exist?("yahoo:cooldown")
    travel 2.minutes
    assert_not cache.exist?("yahoo:cooldown")
  end

  test "a rate limit raised (not returned) by the provider also sets the cooldown" do
    cache = memory_cache!
    hold_pairs(%w[AAA BBB])
    @provider.overrides["AAA"] = -> { raise Provider::YahooFinance::RateLimitError, "429" }

    result = @refresher.refresh_all

    assert result.skipped_for_rate_limit
    assert_equal 1, @provider.calls.size
    assert cache.exist?("yahoo:cooldown")
  end

  test "while the cooldown key is set a run returns immediately: no requests, no changes, no prune" do
    cache = memory_cache!
    cache.write("yahoo:cooldown", true, expires_in: 15.minutes)
    hold_pairs(%w[AAA])
    old = OptionQuote.create!(quote_attrs(contract_symbol: "OLD261001C00010000", underlying: "OLD", option_type: "CALL", strike: 10, expiration: TODAY - 30))

    result = @refresher.refresh_all

    assert_empty @provider.calls
    assert result.skipped_for_rate_limit
    assert_equal [ 0, 0, 0, 0, 0 ], [ result.refreshed, result.failed, result.requests, result.backed_off, result.pruned ]
    assert OptionQuote.exists?(old.id)

    travel 16.minutes
    @refresher.refresh_all
    assert_equal 1, @provider.calls.size, "the run resumes once the key expires"
  end

  test "a non-rate-limit failure does not set the cooldown" do
    cache = memory_cache!
    hold_pairs(%w[AAA])
    @provider.overrides["AAA"] = error_response("boom")

    @refresher.refresh_all

    assert_not cache.exist?("yahoo:cooldown")
  end

  # --- v2: pruning and market date -----------------------------------------------------

  test "prunes rows whose expiration is more than 7 days before the market date" do
    make = ->(symbol, expiration) { OptionQuote.create!(quote_attrs(contract_symbol: symbol, underlying: "OLD", option_type: "CALL", strike: 10, expiration: expiration)) }
    make.call("OLD260101C00010000", TODAY - 30)
    make.call("OLD260102C00010000", TODAY - 8)
    kept_edge = make.call("OLD260103C00010000", TODAY - 7)
    kept_recent = make.call("OLD260104C00010000", TODAY - 3)

    result = @refresher.refresh_all

    assert_equal 2, result.pruned
    assert_equal [ kept_edge, kept_recent ].map(&:id).sort, OptionQuote.pluck(:id).sort
  end

  test "the market date is the New York date, whatever the UTC date or the host TZ" do
    previous = ENV["TZ"]
    ENV["TZ"] = "America/Chicago"
    travel_to Time.utc(2026, 10, 16, 2, 30) # 22:30 ET on Oct 15; already Oct 16 in UTC
    boundary = OptionQuote.create!(quote_attrs(contract_symbol: "OLD261008C00010000", underlying: "OLD", option_type: "CALL", strike: 10, expiration: Date.new(2026, 10, 8)))
    gone = OptionQuote.create!(quote_attrs(contract_symbol: "OLD261007C00010000", underlying: "OLD", option_type: "CALL", strike: 10, expiration: Date.new(2026, 10, 7)))
    broker_account(families(:dylan_family), [ contract("EXP   261015P00100000", TODAY) ])

    result = @refresher.refresh_all

    assert OptionQuote.exists?(boundary.id), "Oct 8 is exactly 7 days before the market date Oct 15"
    assert_not OptionQuote.exists?(gone.id)
    assert_equal 1, result.pruned
    assert_equal [ [ "EXP", TODAY ] ], @provider.calls, "a contract expiring on the market date is still open"
    assert_equal TODAY, OptionQuote::Refresher.market_date
  ensure
    ENV["TZ"] = previous
  end

  test "result carries exactly the six counters" do
    assert_equal %i[refreshed failed skipped_for_rate_limit requests backed_off pruned], OptionQuote::Refresher::Result.members
  end
end
