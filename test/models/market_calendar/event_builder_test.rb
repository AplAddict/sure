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
      Current.reset
      capture_sql_queries { MarketCalendar::EventBuilder.new(accounts: [ account.reload ]).events }.size
    end

    few = run.call(3, Date.new(2026, 1, 3))
    many = run.call(12, Date.new(2026, 3, 1))

    assert_operator many, :<=, few + 3, "queries grew with the number of sales: #{few} -> #{many}"
    Current.reset
    assert_operator MarketCalendar::EventBuilder.new(accounts: [ account.reload ]).events.count { |e| e.event_type == "wash_sale" }, :==, 15
  end

  test "preloads only the latest same-account holding on or before a sale" do
    SnaptradeAccount.stubs(:includes).returns([])
    account = Account.create!(family: families(:dylan_family), name: "Basis boundary", balance: 10_000, currency: "USD",
                              accountable: Investment.new(subtype: "brokerage"))
    other_account = Account.create!(family: families(:empty), name: "Other basis", balance: 10_000, currency: "USD",
                                    accountable: Investment.new(subtype: "brokerage"))
    security = Security.create!(ticker: "BASIS", exchange_mic: "XNAS", name: "Basis Corp")
    sale_date = Date.new(2026, 4, 10)

    account.holdings.create!(security: security, date: sale_date - 3.days, qty: 10, price: 90, amount: 900, currency: "USD", cost_basis: 90)
    expected = account.holdings.create!(security: security, date: sale_date - 1.day, qty: 10, price: 110, amount: 1_100, currency: "USD", cost_basis: 110)
    account.holdings.create!(security: security, date: sale_date + 1.day, qty: 10, price: 10, amount: 100, currency: "USD", cost_basis: 10)
    # Deliberately later than the expected holding, but still on the sale date: dropping the
    # account predicate must therefore choose this row rather than pass by tied ordering.
    other_account.holdings.create!(security: security, date: sale_date, qty: 10, price: 999, amount: 9_990, currency: "USD", cost_basis: 999)
    sale_entry = create_trade(security, account: account, qty: -1, date: sale_date, price: 100)

    Current.reset
    preloaded_sale = MarketCalendar::EventBuilder.new(accounts: [ account ]).send(:accessible_trades).find { |trade| trade.id == sale_entry.entryable_id }

    assert_equal expected.id, preloaded_sale.send(:basis_holding).id
    assert_equal BigDecimal("110"), preloaded_sale.send(:basis_holding).avg_cost.amount
  ensure
    Current.reset
  end

  test "builders for the same accounts in one request share one computation" do
    SnaptradeAccount.stubs(:includes).returns([])
    accounts = users(:family_admin).accessible_accounts.visible.to_a
    MarketCalendar::EventBuilder.any_instance.expects(:fundamental_events).once.returns([])

    first = MarketCalendar::EventBuilder.new(accounts: accounts).events
    second = MarketCalendar::EventBuilder.new(accounts: accounts).events

    assert_equal first, second
    Current.reset
  end

  test "the shared computation is not reused across different account sets" do
    SnaptradeAccount.stubs(:includes).returns([])
    owner = users(:family_admin).accessible_accounts.visible.to_a
    other = users(:empty).accessible_accounts.visible.to_a
    MarketCalendar::EventBuilder.any_instance.expects(:fundamental_events).twice.returns([])

    MarketCalendar::EventBuilder.new(accounts: owner).events
    MarketCalendar::EventBuilder.new(accounts: other).events
    Current.reset
  end
end
