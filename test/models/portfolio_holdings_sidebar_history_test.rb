require "test_helper"

class PortfolioHoldingsSidebarHistoryTest < ActiveSupport::TestCase
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    @user = users(:family_admin)
    @account = @user.family.accounts.create!(name: "History #{SecureRandom.hex(3)}", balance: 5_000, cash_balance: 0, currency: "USD", owner: @user,
                                             status: "active", accountable: Investment.new(subtype: "brokerage"))
    @security = Security.create!(ticker: "HIST", exchange_mic: "XNAS", name: "History Co")
  end

  test "day gain compares against the single most recent earlier snapshot" do
    snapshot(Date.current - 30.days, 80)
    snapshot(Date.current - 1.day, 90)
    snapshot(Date.current, 100)

    position = PortfolioHoldings.new(user: @user).sidebar_accounts.flat_map(&:positions).find { |p| p.ticker == "HIST" }

    assert_equal BigDecimal("100"), position.market_value
    assert_equal BigDecimal("10"), position.day_gain.amount
  end

  test "the previous-snapshot lookup stays one query and does not load the full history" do
    60.times { |i| snapshot(Date.current - (i + 1).days, 50 + i) }
    snapshot(Date.current, 100)

    previous_queries = []
    rows_seen = nil
    ActiveSupport::Notifications.subscribed(->(*, payload) { previous_queries << payload[:sql] if payload[:sql].include?("DISTINCT ON (account_id, security_id, currency)") }, "sql.active_record") do
      rows_seen = PortfolioHoldings.new(user: @user).send(:sidebar_previous_holdings, Holding.where(account_id: @account.id, date: Date.current).to_a)
    end

    assert_equal 1, previous_queries.size
    assert_equal 1, rows_seen.values.flatten.size, "only the latest prior snapshot should be loaded, not all 60"
  end

  private
    def snapshot(date, price)
      @account.holdings.create!(security: @security, date: date, qty: 1, price: price, amount: price, currency: "USD", cost_basis: 70, cost_basis_source: "provider")
    end
end
