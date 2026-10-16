require "test_helper"

class MarketCalendar::EventBuilderTest < ActiveSupport::TestCase
  include EntriesTestHelper

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

  test "uses only the accounts supplied by the signed-in user scope" do
    owner_accounts = users(:family_admin).accessible_accounts
    other_user_accounts = users(:empty).accessible_accounts

    owner_tickers = MarketCalendar::EventBuilder.new(accounts: owner_accounts).send(:held_securities).map(&:ticker)
    other_tickers = MarketCalendar::EventBuilder.new(accounts: other_user_accounts).send(:held_securities).map(&:ticker)

    assert_includes owner_tickers, "AAPL"
    assert_not_includes other_tickers, "AAPL"
  end

  test "reports no wash-sale candidates when no matching recorded trade evidence exists" do
    SnaptradeAccount.stubs(:includes).returns([])

    status = MarketCalendar::EventBuilder.new(accounts: []).wash_sale_status

    assert_not status[:available]
    assert_match(/No calculated wash-sale candidates/i, status[:reason])
  end

  test "wash-sale scan costs the same number of queries however many sales there are" do
    SnaptradeAccount.stubs(:includes).returns([])
    account = Account.create!(family: families(:dylan_family), name: "Perf brokerage", balance: 10_000, currency: "USD",
                              accountable: Investment.new(subtype: "brokerage"))
    security = Security.create!(ticker: "PERF", exchange_mic: "XNAS", name: "Perf Corp")
    Security::Price.create!(security: security, date: Date.new(2026, 1, 2), price: 100, currency: "USD")
    account.holdings.create!(security: security, date: Date.new(2026, 1, 2), qty: 100, price: 100, amount: 10_000, currency: "USD", cost_basis: 120)
    run = lambda do |sales, start|
      sales.times do |i|
        date = start + i
        Security::Price.create!(security: security, date: date, price: 90, currency: "USD")
        account.holdings.create!(security: security, date: date, qty: 100, price: 90, amount: 9_000, currency: "USD", cost_basis: 120)
        create_trade(security, account: account, qty: -1, date: date, price: 90)
      end
      capture_sql_queries { MarketCalendar::EventBuilder.new(accounts: [ account.reload ]).events }.size
    end

    few = run.call(3, Date.new(2026, 1, 3))
    many = run.call(12, Date.new(2026, 3, 1))

    assert_operator many, :<=, few + 3, "queries grew with the number of sales: #{few} -> #{many}"
    assert_operator MarketCalendar::EventBuilder.new(accounts: [ account.reload ]).events.count { |e| e.event_type == "wash_sale" }, :==, 15
  end
end
