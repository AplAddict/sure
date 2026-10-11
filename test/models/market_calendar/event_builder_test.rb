require "test_helper"

class MarketCalendar::EventBuilderTest < ActiveSupport::TestCase
  test "derives earnings and ex-dividend events from held security fundamentals" do
    fundamental = Struct.new(:next_earnings_date, :ex_dividend_date, :available?, :stale?).new("2026-10-15", "2026-10-20", true, false)
    security = Struct.new(:id, :ticker, :name, :fundamental).new("security-1", "AAPL", "Apple Inc.", fundamental)
    holding = Struct.new(:security).new(security)
    account = Struct.new(:id, :current_holdings).new("account-1", [ holding ])
    SnaptradeAccount.stubs(:includes).returns([])

    builder = MarketCalendar::EventBuilder.new(accounts: [ account ], now: Time.zone.parse("2026-10-10 12:00 UTC"))

    assert_equal [ "earnings", "ex_dividend" ], builder.events.map(&:event_type)
    assert_equal [ Date.new(2026, 10, 15), Date.new(2026, 10, 20) ], builder.events.map(&:date)
    assert_equal "AAPL — Earnings", builder.events.first.title
    assert_equal Date.new(2026, 10, 15), builder.events.first.end_date
  end

  test "reports no wash-sale candidates when no matching recorded trade evidence exists" do
    SnaptradeAccount.stubs(:includes).returns([])

    status = MarketCalendar::EventBuilder.new(accounts: []).wash_sale_status

    assert_not status[:available]
    assert_match(/No calculated wash-sale candidates/i, status[:reason])
  end
end
