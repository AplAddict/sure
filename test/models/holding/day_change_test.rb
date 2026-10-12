require "test_helper"

# Day gain is the change from the previous trading day's close to the latest
# price, on the shares held at that close. It must not come from comparing
# calendar-day snapshots, which carry Friday's price through the weekend and
# lag a stale feed.
class Holding::DayChangeTest < ActiveSupport::TestCase
  MON = Date.new(2026, 10, 12)
  FRI = Date.new(2026, 10, 9)
  THU = Date.new(2026, 10, 8)

  setup do
    @account = families(:empty).accounts.create!(name: "Day #{SecureRandom.hex(3)}", balance: 100, cash_balance: 0, currency: "USD", accountable: Investment.new)
    @security = Security.create!(ticker: "DAY#{SecureRandom.hex(2).upcase}", name: "Day")
    travel_to Time.utc(2026, 10, 12, 15, 0) # 11:00 ET, session open
  end

  teardown { travel_back }

  test "trading day: latest price against the previous weekday's close" do
    close(THU, 100)
    close(FRI, 110)
    holding = snap(MON, qty: 2, price: 112)
    snap(FRI, qty: 2, price: 110)

    change = Holding::DayChange.for([ holding ])[holding.id]

    assert_equal 4, change.value.amount
    assert_equal 224, change.current.amount
    assert_equal 220, change.previous.amount
  end

  test "weekend: shows Friday's move, not a flat zero from carried-forward snapshots" do
    travel_to Time.utc(2026, 10, 11, 16, 0) # Sunday
    close(THU, 100)
    close(FRI, 110)
    close(Date.new(2026, 10, 10), 110)
    close(Date.new(2026, 10, 11), 110)
    snap(THU, qty: 3, price: 100)
    snap(FRI, qty: 3, price: 110)
    holding = snap(Date.new(2026, 10, 11), qty: 3, price: 110)

    change = Holding::DayChange.for([ holding ])[holding.id]

    assert_equal 30, change.value.amount
  end

  test "a position whose price was not refreshed this session is unavailable, not flat" do
    close(THU, 100)
    close(FRI, 110)
    holding = snap(Date.new(2026, 10, 10), qty: 2, price: 110)

    assert_nil Holding::DayChange.for([ holding ])[holding.id]
  end

  test "a quantity change since the reference close is unavailable (a trade is not a market gain)" do
    close(FRI, 110)
    snap(FRI, qty: 2, price: 110)
    holding = snap(MON, qty: 5, price: 112)

    assert_nil Holding::DayChange.for([ holding ])[holding.id]
  end

  test "a position opened after the reference close is unavailable" do
    close(FRI, 110)
    holding = snap(MON, qty: 2, price: 112)

    assert_nil Holding::DayChange.for([ holding ])[holding.id]
  end

  test "no price history for the security is unavailable" do
    snap(FRI, qty: 2, price: 110)
    holding = snap(MON, qty: 2, price: 112)

    assert_nil Holding::DayChange.for([ holding ])[holding.id]
  end

  test "a price in another currency than the holding is unavailable" do
    Security::Price.create!(security: @security, date: FRI, price: 110, currency: "EUR")
    snap(FRI, qty: 2, price: 110)
    holding = snap(MON, qty: 2, price: 112)

    assert_nil Holding::DayChange.for([ holding ])[holding.id]
  end

  test "a measured zero move is a zero, not unavailable" do
    close(FRI, 110)
    snap(FRI, qty: 2, price: 110)
    holding = snap(MON, qty: 2, price: 110)

    assert_equal 0, Holding::DayChange.for([ holding ])[holding.id].value.amount
  end

  test "Holding#day_change uses the same calculation" do
    close(FRI, 110)
    snap(FRI, qty: 2, price: 110)
    holding = snap(MON, qty: 2, price: 115)

    assert_equal 10, holding.day_change.value.amount
    assert_in_delta 4.545, holding.day_change.percent, 0.1
  end

  test "batch lookup stays a fixed number of queries" do
    holdings = 5.times.map do |i|
      security = Security.create!(ticker: "DQ#{i}#{SecureRandom.hex(2).upcase}", name: "x")
      Security::Price.create!(security: security, date: FRI, price: 10, currency: "USD")
      @account.holdings.create!(security: security, date: FRI, qty: 1, price: 10, amount: 10, currency: "USD")
      @account.holdings.create!(security: security, date: MON, qty: 1, price: 11, amount: 11, currency: "USD")
    end

    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { Holding::DayChange.for(holdings) }

    assert_operator count, :<=, 3
  end

  test "a price written overnight, before the session opened, is unavailable rather than a flat zero" do
    close(FRI, 110)
    snap(FRI, qty: 2, price: 110)
    holding = snap(MON, qty: 2, price: 110)
    holding.update_columns(updated_at: Time.utc(2026, 10, 12, 3, 17))

    assert_nil Holding::DayChange.for([ holding ])[holding.id]
  end

  test "before the open on a trading day it is still Friday's move" do
    travel_to Time.utc(2026, 10, 12, 12, 0) # 8:00 ET, before the 9:30 open
    close(THU, 100)
    close(FRI, 110)
    snap(THU, qty: 2, price: 100)
    snap(FRI, qty: 2, price: 110)
    holding = snap(MON, qty: 2, price: 110)
    holding.update_columns(updated_at: Time.utc(2026, 10, 12, 3, 17))

    change = Holding::DayChange.for([ holding ])[holding.id]
    assert_equal 20, change.value.amount
  end

  test "the session starts at the 9:30 ET open" do
    assert_equal Date.new(2026, 10, 9), Holding::DayChange.new([], now: Time.utc(2026, 10, 12, 13, 29)).session_date
    assert_equal Date.new(2026, 10, 12), Holding::DayChange.new([], now: Time.utc(2026, 10, 12, 13, 31)).session_date
    assert_equal Date.new(2026, 10, 9), Holding::DayChange.new([], now: Time.utc(2026, 10, 11, 15, 0)).session_date
  end

  test "uses a live price refreshed after the open when the broker snapshot predates it" do
    close(FRI, 110)
    snap(FRI, qty: 2, price: 110)
    holding = snap(MON, qty: 2, price: 110)
    holding.update_columns(updated_at: Time.utc(2026, 10, 12, 3, 17))
    Security::Price.create!(security: @security, date: MON, price: 115, currency: "USD", provisional: true)

    change = Holding::DayChange.for([ holding ])[holding.id]

    assert_equal 10, change.value.amount
    assert_equal 230, change.current.amount
  end

  test "ignores a Monday price row that was written before the open" do
    close(FRI, 110)
    snap(FRI, qty: 2, price: 110)
    holding = snap(MON, qty: 2, price: 110)
    holding.update_columns(updated_at: Time.utc(2026, 10, 12, 3, 17))
    row = Security::Price.create!(security: @security, date: MON, price: 110, currency: "USD", provisional: true)
    row.update_columns(updated_at: Time.utc(2026, 10, 12, 7, 31))

    assert_nil Holding::DayChange.for([ holding ])[holding.id]
  end

  test "ignores a live price in another currency" do
    close(FRI, 110)
    snap(FRI, qty: 2, price: 110)
    holding = snap(MON, qty: 2, price: 110)
    holding.update_columns(updated_at: Time.utc(2026, 10, 12, 3, 17))
    Security::Price.create!(security: @security, date: MON, price: 115, currency: "EUR", provisional: true)

    assert_nil Holding::DayChange.for([ holding ])[holding.id]
  end

  test "a stale position snapshot stays unavailable even with a live price" do
    close(FRI, 110)
    snap(FRI, qty: 2, price: 110)
    holding = snap(Date.new(2026, 10, 10), qty: 2, price: 110)
    Security::Price.create!(security: @security, date: MON, price: 115, currency: "USD", provisional: true)

    assert_nil Holding::DayChange.for([ holding ])[holding.id]
  end

  private
    def close(date, price)
      Security::Price.create!(security: @security, date: date, price: price, currency: "USD")
    end

    def snap(date, qty:, price:)
      @account.holdings.create!(security: @security, date: date, qty: qty, price: price, amount: qty * price, currency: "USD")
    end
end
