require "test_helper"

class InvestmentWatchlistDiscoveryTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("ai_watchlist_enabled" => true, "ai_watchlist_auto_add_enabled" => true, "ai_watchlist_expiry_days" => 30))
    @security = Security.create!(ticker: "DISCO", exchange_mic: "XNAS", name: "Discovery", offline: true, offline_reason: Security::RESEARCH_ONLY_REASON)
    SecurityFundamental.create!(security: @security, fetched_at: 1.hour.ago, payload: { "recommendation" => "buy", "analyst_count" => 8, "revenue_growth" => 0.2, "earnings_growth" => 0.1, "next_earnings_date" => 14.days.from_now.to_date.iso8601 })
    @scan = scan_for(generated_at: 2.hours.ago, rows: [ row("DISCO") ])
  end

  def row(ticker, **overrides)
    { "ticker" => ticker, "name" => ticker.capitalize, "isETF" => false, "quoteType" => "EQUITY", "regularMarketPrice" => 50.0,
      "return20dPct" => 8.0, "return63dPct" => 20.0, "relativeStrength20dVsQQQ" => 4.0, "relativeStrength63dVsSPY" => 12.0,
      "distanceFrom52WeekHighPct" => -4.0, "regularDollarVolume" => 80_000_000,
      "aboveMovingAverages" => { "ma20" => true, "ma50" => true, "ma200" => true } }.merge(overrides)
  end

  def scan_for(generated_at:, rows:)
    { "generatedAt" => generated_at.utc.iso8601, "tickers" => rows }
  end

  def discover(scan = @scan, user: @user)
    InvestmentWatchlistDiscovery.new(user: user, scan: scan)
  end

  test "adds one sourced, expiring candidate only for an opted-in user, from the market-wide scan" do
    result = discover.add_candidate
    assert_equal :added, result.reason
    assert_equal @security, result.entry.security
    assert result.entry.expires_at > Time.current
    assert_equal "assistant", result.entry.source
    assert_match "above its 20, 50 and 200-day averages", result.entry.thesis
    assert_match "not a trade recommendation", result.entry.thesis
    assert_equal :daily_limit, discover.add_candidate.reason
  end

  test "works for securities that have no research snapshot at all" do
    assert_nil @security.research_snapshot
    assert_equal :added, discover.add_candidate.reason
  end

  test "stale scan, stale fundamentals or disabled setting add nothing" do
    stale = scan_for(generated_at: 3.days.ago, rows: [ row("DISCO") ])
    assert_equal :no_fresh_evidence, discover(stale).add_candidate.reason

    @security.fundamental.update!(fetched_at: 3.days.ago)
    assert_equal :no_fresh_evidence, discover.add_candidate.reason

    @security.fundamental.update!(fetched_at: 1.hour.ago)
    @user.update!(preferences: @user.preferences.merge("ai_watchlist_auto_add_enabled" => false))
    assert_equal :disabled, discover.add_candidate.reason
  end

  test "an unreadable or missing scan fails closed" do
    assert_equal :no_fresh_evidence, discover(nil).add_candidate.reason
    assert_equal :no_fresh_evidence, discover({ "tickers" => [] }).add_candidate.reason
    assert_equal :no_fresh_evidence, discover({ "generatedAt" => "garbage", "tickers" => [ row("DISCO") ] }).add_candidate.reason
  end

  test "rejects ETFs, thin liquidity, a broken trend, negative relative strength and chasing" do
    [ { "isETF" => true }, { "regularDollarVolume" => 1_000_000 }, { "aboveMovingAverages" => { "ma20" => true, "ma50" => false, "ma200" => true } },
      { "relativeStrength20dVsQQQ" => -2.0 }, { "relativeStrength63dVsSPY" => -1.0 }, { "return20dPct" => 45.0 }, { "distanceFrom52WeekHighPct" => -45.0 } ].each do |bad|
      assert_equal :no_fresh_evidence, discover(scan_for(generated_at: 1.hour.ago, rows: [ row("DISCO", **bad) ])).add_candidate.reason, "should reject #{bad}"
    end
  end

  test "requires buy consensus with enough analysts and no earnings within a week" do
    @security.fundamental.update!(payload: @security.fundamental.payload.merge("recommendation" => "hold"))
    assert_equal :no_fresh_evidence, discover.add_candidate.reason
    @security.fundamental.update!(payload: @security.fundamental.payload.merge("recommendation" => "buy", "analyst_count" => 2))
    assert_equal :no_fresh_evidence, discover.add_candidate.reason
    @security.fundamental.update!(payload: @security.fundamental.payload.merge("analyst_count" => 8, "next_earnings_date" => 3.days.from_now.to_date.iso8601))
    assert_equal :no_fresh_evidence, discover.add_candidate.reason
  end

  test "skips what the member already holds or already has on the watchlist, using only their own accounts" do
    account = @user.family.accounts.create!(name: "Mine #{SecureRandom.hex(3)}", balance: 1, cash_balance: 0, currency: "USD", owner: @user, accountable: Investment.new)
    Holding.create!(account: account, security: @security, date: Date.current, qty: 1, price: 1, amount: 1, currency: "USD")
    assert_equal :no_fresh_evidence, discover.add_candidate.reason
  end

  test "another member's private holding or watchlist never hides a candidate from this member" do
    other = users(:family_member)
    account = @user.family.accounts.create!(name: "Theirs #{SecureRandom.hex(3)}", balance: 1, cash_balance: 0, currency: "USD", owner: other, accountable: Investment.new)
    Holding.create!(account: account, security: @security, date: Date.current, qty: 1, price: 1, amount: 1, currency: "USD")
    other.research_watchlist_entries.create!(security: @security, status: "watching", priority: 3)
    assert_equal :added, discover.add_candidate.reason
  end

  test "ranks by analyst coverage and relative strength, deterministically" do
    strong = Security.create!(ticker: "STRNG", exchange_mic: "XNAS", name: "Strong", offline: true, offline_reason: Security::RESEARCH_ONLY_REASON)
    SecurityFundamental.create!(security: strong, fetched_at: 1.hour.ago, payload: { "recommendation" => "strong_buy", "analyst_count" => 25, "next_earnings_date" => 30.days.from_now.to_date.iso8601 })
    rows = [ row("DISCO"), row("STRNG", "relativeStrength20dVsQQQ" => 9.0) ]

    assert_equal strong, discover(scan_for(generated_at: 1.hour.ago, rows: rows)).add_candidate.entry.security
  end

  test "does not read the scan's portfolio flags, which describe another person's accounts" do
    flagged = row("DISCO", "isPortfolioSymbol" => true, "isAgenticHeld" => true, "isTradeIdea" => true)
    assert_equal :added, discover(scan_for(generated_at: 1.hour.ago, rows: [ flagged ])).add_candidate.reason
  end
end
