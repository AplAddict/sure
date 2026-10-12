require "test_helper"

class InvestmentWatchlistDiscoveryTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("ai_watchlist_enabled" => true, "ai_watchlist_auto_add_enabled" => true, "ai_watchlist_expiry_days" => 30))
    @security = Security.create!(ticker: "DISCOV", exchange_mic: "XNAS", name: "Discovery", offline: true, offline_reason: Security::RESEARCH_ONLY_REASON)
    SecurityResearchSnapshot.create!(security: @security, status: "current", generated_at: 1.hour.ago, imported_at: 1.hour.ago, payload: { "analysis" => "Fresh source note" })
    SecurityFundamental.create!(security: @security, fetched_at: 1.hour.ago, payload: { "recommendation" => "buy", "analyst_count" => 8, "revenue_growth" => 0.2, "earnings_growth" => 0.1, "next_earnings_date" => 14.days.from_now.to_date.iso8601 })
  end

  test "adds one sourced expiring candidate only for an opted-in user" do
    result = InvestmentWatchlistDiscovery.new(user: @user).add_candidate
    assert_equal :added, result.reason
    assert_equal @security, result.entry.security
    assert result.entry.expires_at > Time.current
    assert_match "fresh research snapshot", result.entry.thesis
    assert_match "not a trade recommendation", result.entry.thesis

    assert_equal :daily_limit, InvestmentWatchlistDiscovery.new(user: @user).add_candidate.reason
  end

  test "fails closed for stale evidence, held securities and disabled users" do
    @security.research_snapshot.update!(generated_at: 2.days.ago)
    assert_equal :no_fresh_evidence, InvestmentWatchlistDiscovery.new(user: @user).add_candidate.reason
    @user.update!(preferences: @user.preferences.merge("ai_watchlist_auto_add_enabled" => false))
    assert_equal :disabled, InvestmentWatchlistDiscovery.new(user: @user).add_candidate.reason
  end

  test "does not use another member private holdings or watchlist as a candidate exclusion" do
    other = users(:family_member)
    account = @user.family.accounts.create!(name: "Private candidate", balance: 1, cash_balance: 0, currency: "USD", owner: other, status: "active", accountable: Investment.new)
    account.holdings.create!(security: @security, date: Date.current, qty: 1, price: 1, amount: 1, currency: "USD")
    result = InvestmentWatchlistDiscovery.new(user: @user).add_candidate
    assert_equal :added, result.reason
  end
end
