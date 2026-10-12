require "test_helper"

class PortfolioHoldingsSidebarHistoryTest < ActiveSupport::TestCase
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    travel_to Time.zone.local(2026, 10, 12, 11, 0)
    @user = users(:family_admin)
    @account = @user.family.accounts.create!(name: "History #{SecureRandom.hex(3)}", balance: 5_000, cash_balance: 0, currency: "USD", owner: @user,
                                             status: "active", accountable: Investment.new(subtype: "brokerage"))
    @security = Security.create!(ticker: "HIST", exchange_mic: "XNAS", name: "History Co")
  end

  teardown { travel_back }

  test "sidebar day gain is today's price against the previous trading day's close on the same shares" do
    Security::Price.create!(security: @security, date: Date.new(2026, 10, 9), price: 90, currency: "USD")
    snapshot(Date.new(2026, 10, 9), 90)
    snapshot(Date.current, 100)

    position = sidebar_position

    assert_equal BigDecimal("100"), position.market_value
    assert_equal BigDecimal("10"), position.day_gain.amount
  end

  test "sidebar day gain is unavailable without a previous close, never a guessed zero" do
    snapshot(Date.current, 100)

    assert_nil sidebar_position.day_gain
  end

  test "sidebar day gain is unavailable when the price was not refreshed this session" do
    Security::Price.create!(security: @security, date: Date.new(2026, 10, 9), price: 90, currency: "USD")
    snapshot(Date.new(2026, 10, 9), 90)
    snapshot(Date.new(2026, 10, 10), 90)
    @account.holdings.where(date: Date.current).delete_all

    assert_nil sidebar_position&.day_gain
  end

  private
    def sidebar_position
      PortfolioHoldings.new(user: @user).sidebar_accounts.flat_map(&:positions).find { |p| p.ticker == "HIST" }
    end

    def snapshot(date, price)
      @account.holdings.create!(security: @security, date: date, qty: 1, price: price, amount: price, currency: "USD", cost_basis: 70, cost_basis_source: "provider")
    end
end
