require "test_helper"

class Options::MarketCalendarTest < ActiveSupport::TestCase
  Cal = Options::MarketCalendar
  NY = ActiveSupport::TimeZone["America/New_York"]

  def ny(year, month, day, hour = 12, minute = 0, second = 0)
    NY.local(year, month, day, hour, minute, second)
  end

  def d(year, month, day)
    Date.new(year, month, day)
  end

  def with_tz(zone)
    original = ENV["TZ"]
    ENV["TZ"] = zone
    yield
  ensure
    original.nil? ? ENV.delete("TZ") : ENV["TZ"] = original
  end

  # ---- holidays -------------------------------------------------------------------------

  test "2026 holidays are exactly the NYSE full-closure days with weekend observance" do
    expected = [
      d(2026, 1, 1), d(2026, 1, 19), d(2026, 2, 16), d(2026, 4, 3), d(2026, 5, 25),
      d(2026, 6, 19), d(2026, 7, 3), d(2026, 9, 7), d(2026, 11, 26), d(2026, 12, 25)
    ]
    assert_kind_of Set, Cal.holidays(2026)
    assert_equal expected.to_set, Cal.holidays(2026)
  end

  test "2027 holidays observe Saturday on Friday and Sunday on Monday" do
    expected = [
      d(2027, 1, 1), d(2027, 1, 18), d(2027, 2, 15), d(2027, 3, 26), d(2027, 5, 31),
      d(2027, 6, 18), d(2027, 7, 5), d(2027, 9, 6), d(2027, 11, 25), d(2027, 12, 24)
    ]
    assert_equal expected.to_set, Cal.holidays(2027)
  end

  test "saturday juneteenth is observed on friday the 18th and sunday july 4th on monday the 5th" do
    assert_equal false, Cal.trading_day?(d(2027, 6, 18))
    assert_equal false, Cal.trading_day?(d(2027, 7, 5))
    assert_equal false, Cal.trading_day?(d(2027, 12, 24))
    assert_equal true, Cal.trading_day?(d(2027, 6, 17))
    assert_equal true, Cal.trading_day?(d(2027, 7, 6))
  end

  test "saturday july 4th 2026 is observed on friday july 3rd" do
    assert_equal false, Cal.trading_day?(d(2026, 7, 3))
    assert_equal true, Cal.trading_day?(d(2026, 7, 2))
  end

  test "new years day on a saturday is not observed on the prior friday" do
    assert d(2028, 1, 1).saturday?
    assert_equal true, Cal.trading_day?(d(2027, 12, 31))
    refute_includes Cal.holidays(2027), d(2027, 12, 31)
    refute_includes Cal.holidays(2028), d(2027, 12, 31)
  end

  test "new years day on a sunday is observed on monday" do
    assert_equal true, d(2023, 1, 1).sunday?
    assert_includes Cal.holidays(2023), d(2023, 1, 2)
    assert_equal false, Cal.trading_day?(d(2023, 1, 2))
  end

  test "good friday follows the anonymous gregorian easter algorithm" do
    {
      2024 => d(2024, 3, 29), 2025 => d(2025, 4, 18), 2026 => d(2026, 4, 3),
      2027 => d(2027, 3, 26), 2028 => d(2028, 4, 14), 2038 => d(2038, 4, 23)
    }.each do |year, good_friday|
      assert_includes Cal.holidays(year), good_friday, "Good Friday #{year}"
      assert_equal false, Cal.trading_day?(good_friday)
    end
  end

  test "floating monday holidays land on the right weeks" do
    assert_includes Cal.holidays(2026), d(2026, 1, 19)   # 3rd Mon Jan
    assert_includes Cal.holidays(2026), d(2026, 2, 16)   # 3rd Mon Feb
    assert_includes Cal.holidays(2026), d(2026, 5, 25)   # last Mon May
    assert_includes Cal.holidays(2026), d(2026, 9, 7)    # 1st Mon Sep
    assert_includes Cal.holidays(2027), d(2027, 5, 31)   # last Mon May is the 31st
    assert_includes Cal.holidays(2027), d(2027, 9, 6)
  end

  test "thanksgiving is the fourth thursday but the friday after is a trading day" do
    assert_equal false, Cal.trading_day?(d(2026, 11, 26))
    assert_equal true, Cal.trading_day?(d(2026, 11, 27))
    assert_equal false, Cal.trading_day?(d(2027, 11, 25))
    assert_equal true, Cal.trading_day?(d(2027, 11, 26))
  end

  test "weekends are never trading days" do
    assert_equal false, Cal.trading_day?(d(2026, 10, 17))
    assert_equal false, Cal.trading_day?(d(2026, 10, 18))
    assert_equal true, Cal.trading_day?(d(2026, 10, 16))
    assert_equal true, Cal.trading_day?(d(2026, 10, 19))
  end

  test "trading_day? returns a strict boolean" do
    assert_same true, Cal.trading_day?(d(2026, 10, 15))
    assert_same false, Cal.trading_day?(d(2026, 12, 25))
  end

  # ---- market_date ----------------------------------------------------------------------

  test "market_date is the new york calendar date" do
    assert_equal d(2026, 10, 15), Cal.market_date(Time.utc(2026, 10, 15, 15, 0, 0))
    # 01:00 UTC on the 16th is 21:00 EDT on the 15th
    assert_equal d(2026, 10, 15), Cal.market_date(Time.utc(2026, 10, 16, 1, 0, 0))
    assert_equal d(2026, 10, 16), Cal.market_date(Time.utc(2026, 10, 16, 4, 0, 0))
  end

  test "friday evening in new york is still friday even though utc has rolled to saturday" do
    friday_night = ny(2026, 10, 16, 23, 30)
    assert_equal d(2026, 10, 17), friday_night.utc.to_date, "precondition: UTC date flipped"
    assert_equal d(2026, 10, 16), Cal.market_date(friday_night)
    assert_equal d(2026, 10, 16), Cal.market_date(friday_night.utc)
    assert_equal d(2026, 10, 16), Cal.latest_session(friday_night)
  end

  test "market_date handles both dst transition days" do
    # 2026-03-08 spring forward: 06:59 UTC is 01:59 EST, 07:00 UTC is 03:00 EDT
    assert_equal d(2026, 3, 8), Cal.market_date(Time.utc(2026, 3, 8, 6, 59))
    assert_equal d(2026, 3, 8), Cal.market_date(Time.utc(2026, 3, 8, 7, 0))
    assert_equal d(2026, 3, 7), Cal.market_date(Time.utc(2026, 3, 8, 4, 59))
    # 2026-11-01 fall back: 05:30 UTC is 01:30 EDT, 06:30 UTC is 01:30 EST
    assert_equal d(2026, 11, 1), Cal.market_date(Time.utc(2026, 11, 1, 5, 30))
    assert_equal d(2026, 11, 1), Cal.market_date(Time.utc(2026, 11, 1, 6, 30))
    assert_equal d(2026, 10, 31), Cal.market_date(Time.utc(2026, 11, 1, 3, 59))
    assert_equal d(2026, 11, 1), Cal.market_date(Time.utc(2026, 11, 1, 4, 0))
  end

  # ---- latest_session / session_open? ---------------------------------------------------

  test "latest_session is today only once the 09:30 open has happened" do
    assert_equal d(2026, 10, 14), Cal.latest_session(ny(2026, 10, 15, 9, 29, 59))
    assert_equal d(2026, 10, 15), Cal.latest_session(ny(2026, 10, 15, 9, 30, 0))
    assert_equal d(2026, 10, 15), Cal.latest_session(ny(2026, 10, 15, 16, 20))
    assert_equal d(2026, 10, 15), Cal.latest_session(ny(2026, 10, 15, 23, 59, 59))
  end

  test "friday settle viewed monday 07:00 ET is still the friday session" do
    monday_early = ny(2026, 10, 19, 7, 0)
    assert_equal d(2026, 10, 16), Cal.latest_session(monday_early)
    assert_equal d(2026, 10, 16), Cal.latest_session(ny(2026, 10, 19, 9, 29, 59))
    assert_equal d(2026, 10, 19), Cal.latest_session(ny(2026, 10, 19, 9, 30))
  end

  test "saturday and sunday resolve to friday" do
    assert_equal d(2026, 10, 16), Cal.latest_session(ny(2026, 10, 17, 12))
    assert_equal d(2026, 10, 16), Cal.latest_session(ny(2026, 10, 18, 23, 59))
  end

  test "good friday long weekend resolves to thursday until monday opens" do
    assert_equal d(2026, 4, 2), Cal.latest_session(ny(2026, 4, 3, 12))
    assert_equal d(2026, 4, 2), Cal.latest_session(ny(2026, 4, 4, 12))
    assert_equal d(2026, 4, 2), Cal.latest_session(ny(2026, 4, 6, 7, 0))
    assert_equal d(2026, 4, 6), Cal.latest_session(ny(2026, 4, 6, 9, 30))
    assert_equal d(2027, 3, 25), Cal.latest_session(ny(2027, 3, 26, 14))
    assert_equal d(2027, 3, 25), Cal.latest_session(ny(2027, 3, 29, 8))
  end

  test "thanksgiving and the friday after" do
    assert_equal d(2026, 11, 25), Cal.latest_session(ny(2026, 11, 26, 11))
    assert_equal d(2026, 11, 25), Cal.latest_session(ny(2026, 11, 27, 9, 29))
    assert_equal d(2026, 11, 27), Cal.latest_session(ny(2026, 11, 27, 9, 30))
    assert_equal d(2026, 11, 27), Cal.latest_session(ny(2026, 11, 29, 12))
    assert_equal d(2027, 11, 24), Cal.latest_session(ny(2027, 11, 25, 12))
  end

  test "juneteenth, memorial day and labor day long weekends" do
    assert_equal d(2026, 6, 18), Cal.latest_session(ny(2026, 6, 19, 12))
    assert_equal d(2026, 6, 18), Cal.latest_session(ny(2026, 6, 22, 9, 0))
    assert_equal d(2026, 5, 22), Cal.latest_session(ny(2026, 5, 25, 12))
    assert_equal d(2026, 9, 4), Cal.latest_session(ny(2026, 9, 7, 12))
    assert_equal d(2027, 5, 28), Cal.latest_session(ny(2027, 5, 31, 12))
  end

  test "saturday juneteenth observed friday 2027" do
    assert_equal d(2027, 6, 17), Cal.latest_session(ny(2027, 6, 18, 12))
    assert_equal d(2027, 6, 17), Cal.latest_session(ny(2027, 6, 21, 9, 0))
    assert_equal d(2027, 6, 21), Cal.latest_session(ny(2027, 6, 21, 9, 30))
  end

  test "observed saturday and sunday independence days" do
    assert_equal d(2026, 7, 2), Cal.latest_session(ny(2026, 7, 3, 12))
    assert_equal d(2026, 7, 2), Cal.latest_session(ny(2026, 7, 6, 8))
    assert_equal d(2027, 7, 2), Cal.latest_session(ny(2027, 7, 5, 12))
    assert_equal d(2027, 7, 2), Cal.latest_session(ny(2027, 7, 6, 9, 0))
    assert_equal d(2027, 7, 6), Cal.latest_session(ny(2027, 7, 6, 9, 30))
  end

  test "christmas observed on friday december 24 2027" do
    assert_equal d(2027, 12, 23), Cal.latest_session(ny(2027, 12, 24, 12))
    assert_equal d(2027, 12, 23), Cal.latest_session(ny(2027, 12, 27, 9, 0))
  end

  test "new years day 2027 holiday rolls back across the year boundary" do
    assert_equal d(2026, 12, 31), Cal.latest_session(ny(2027, 1, 1, 12))
    assert_equal d(2026, 12, 31), Cal.latest_session(ny(2027, 1, 4, 9, 0))
  end

  test "session_open? covers [09:30, 16:00) on ordinary trading days only" do
    assert_same false, Cal.session_open?(ny(2026, 10, 15, 9, 29, 59))
    assert_same true, Cal.session_open?(ny(2026, 10, 15, 9, 30, 0))
    assert_same true, Cal.session_open?(ny(2026, 10, 15, 15, 59, 59))
    assert_same false, Cal.session_open?(ny(2026, 10, 15, 16, 0, 0))
    assert_same false, Cal.session_open?(ny(2026, 10, 17, 11, 0))
    assert_same false, Cal.session_open?(ny(2026, 11, 26, 11, 0))
    assert_same false, Cal.session_open?(ny(2026, 4, 3, 11, 0))
  end

  test "supported early closes end the session at 13:00 new york time" do
    thanksgiving_friday = d(2026, 11, 27)
    christmas_eve = d(2026, 12, 24)
    july_early_close = d(2025, 7, 3)

    [ thanksgiving_friday, christmas_eve, july_early_close ].each do |date|
      assert Cal.early_close?(date), "#{date} should be an early close"
      assert_equal 13, Cal.close_time(date).hour
      assert_equal 0, Cal.close_time(date).min
    end

    assert_same true, Cal.session_open?(ny(2026, 11, 27, 12, 59, 59))
    assert_same false, Cal.session_open?(ny(2026, 11, 27, 13, 0, 0))
  end

  test "full closures never become early closes and ordinary dates retain a 16:00 close" do
    observed_independence_day = d(2026, 7, 3)
    observed_christmas_eve = d(2027, 12, 24)

    refute Cal.trading_day?(observed_independence_day)
    refute Cal.early_close?(observed_independence_day)
    assert_same false, Cal.session_open?(ny(2026, 7, 3, 12, 0, 0))
    refute Cal.trading_day?(observed_christmas_eve)
    refute Cal.early_close?(observed_christmas_eve), "2027 Christmas Eve is the observed Christmas closure"
    assert_equal 16, Cal.close_time(d(2026, 10, 15)).hour
  end

  test "session_open? follows new york wall clock across dst transitions" do
    # Fri 2026-03-06 is EST: 14:30 UTC is the open. Mon 2026-03-09 is EDT: 13:30 UTC is the open.
    assert_same false, Cal.session_open?(Time.utc(2026, 3, 6, 14, 29))
    assert_same true, Cal.session_open?(Time.utc(2026, 3, 6, 14, 30))
    assert_same false, Cal.session_open?(Time.utc(2026, 3, 9, 13, 29))
    assert_same true, Cal.session_open?(Time.utc(2026, 3, 9, 13, 30))
    assert_same true, Cal.session_open?(Time.utc(2026, 3, 9, 19, 59))
    assert_same false, Cal.session_open?(Time.utc(2026, 3, 9, 20, 0))
    # Fri 2026-10-30 is EDT, Mon 2026-11-02 is EST
    assert_same true, Cal.session_open?(Time.utc(2026, 10, 30, 13, 30))
    assert_same false, Cal.session_open?(Time.utc(2026, 11, 2, 13, 30))
    assert_same true, Cal.session_open?(Time.utc(2026, 11, 2, 14, 30))
    assert_same false, Cal.session_open?(Time.utc(2026, 11, 2, 21, 0))
  end

  test "dst sundays are not trading days and resolve to friday" do
    assert_equal d(2026, 3, 6), Cal.latest_session(ny(2026, 3, 8, 12))
    assert_equal d(2026, 10, 30), Cal.latest_session(ny(2026, 11, 1, 12))
    assert_same false, Cal.session_open?(ny(2026, 3, 8, 12))
    assert_same false, Cal.session_open?(ny(2026, 11, 1, 12))
  end

  # ---- trading_days_between / previous_session / close_time -----------------------------

  test "trading_days_between is a half-open range (from, to]" do
    assert_equal 1, Cal.trading_days_between(d(2026, 10, 15), d(2026, 10, 16))
    assert_equal 0, Cal.trading_days_between(d(2026, 10, 15), d(2026, 10, 15))
    assert_equal 0, Cal.trading_days_between(d(2026, 10, 16), d(2026, 10, 15))
    assert_equal 5, Cal.trading_days_between(d(2026, 10, 9), d(2026, 10, 16))
  end

  test "friday to monday is one trading day and friday to saturday is zero" do
    assert_equal 1, Cal.trading_days_between(d(2026, 10, 16), d(2026, 10, 19))
    assert_equal 0, Cal.trading_days_between(d(2026, 10, 16), d(2026, 10, 17))
    assert_equal 0, Cal.trading_days_between(d(2026, 10, 16), d(2026, 10, 18))
  end

  test "trading_days_between skips holidays" do
    assert_equal 1, Cal.trading_days_between(d(2026, 4, 2), d(2026, 4, 6))   # Good Friday
    assert_equal 0, Cal.trading_days_between(d(2026, 4, 2), d(2026, 4, 3))
    assert_equal 2, Cal.trading_days_between(d(2026, 11, 24), d(2026, 11, 27)) # Wed + Fri, not Thu
    assert_equal 1, Cal.trading_days_between(d(2027, 7, 2), d(2027, 7, 6))    # Mon Jul 5 observed
    assert_equal 1, Cal.trading_days_between(d(2027, 6, 17), d(2027, 6, 21))  # Fri Jun 18 observed
  end

  test "trading_days_between across a year boundary and a leap year" do
    assert_equal 1, Cal.trading_days_between(d(2026, 12, 31), d(2027, 1, 4))
    assert_equal 2, Cal.trading_days_between(d(2028, 2, 28), d(2028, 3, 1))   # Feb 29 exists
  end

  test "previous_session is the trading day strictly before the date" do
    assert_equal d(2026, 10, 15), Cal.previous_session(d(2026, 10, 16))
    assert_equal d(2026, 10, 16), Cal.previous_session(d(2026, 10, 19))
    assert_equal d(2026, 10, 16), Cal.previous_session(d(2026, 10, 18))
    assert_equal d(2026, 10, 16), Cal.previous_session(d(2026, 10, 17))
    assert_equal d(2026, 4, 2), Cal.previous_session(d(2026, 4, 6))
    assert_equal d(2026, 11, 25), Cal.previous_session(d(2026, 11, 27))
    assert_equal d(2026, 11, 27), Cal.previous_session(d(2026, 11, 30))
    assert_equal d(2026, 12, 31), Cal.previous_session(d(2027, 1, 4))
    assert_equal d(2027, 12, 31), Cal.previous_session(d(2028, 1, 3))
  end

  test "close_time is 16:00 new york time on that date" do
    close = Cal.close_time(d(2026, 10, 15))
    assert_kind_of Time, close
    assert_equal Time.utc(2026, 10, 15, 20, 0, 0), close.utc
    assert_equal Time.utc(2026, 11, 2, 21, 0, 0), Cal.close_time(d(2026, 11, 2)).utc
    assert_equal Time.utc(2026, 3, 6, 21, 0, 0), Cal.close_time(d(2026, 3, 6)).utc
    assert_equal Time.utc(2026, 3, 9, 20, 0, 0), Cal.close_time(d(2026, 3, 9)).utc
  end

  test "close_time on the dst transition sundays uses the new offset" do
    assert_equal Time.utc(2026, 3, 8, 20, 0, 0), Cal.close_time(d(2026, 3, 8)).utc
    assert_equal Time.utc(2026, 11, 1, 21, 0, 0), Cal.close_time(d(2026, 11, 1)).utc
  end

  # ---- host timezone independence -------------------------------------------------------

  test "results do not depend on the host TZ environment variable" do
    with_tz("America/Chicago") do
      assert_equal "CDT", Time.local(2026, 10, 16, 12).zone, "precondition: host TZ applied"

      # Chicago wall clock 23:30 Fri is 00:30 Sat in New York
      chicago_friday_night = Time.local(2026, 10, 16, 23, 30)
      assert_equal d(2026, 10, 16), chicago_friday_night.to_date
      assert_equal d(2026, 10, 17), Cal.market_date(chicago_friday_night)
      assert_equal d(2026, 10, 16), Cal.latest_session(chicago_friday_night)

      # Chicago 08:30 is New York 09:30 (open); 08:29 is not
      assert_same false, Cal.session_open?(Time.local(2026, 10, 15, 8, 29, 59))
      assert_same true, Cal.session_open?(Time.local(2026, 10, 15, 8, 30, 0))
      assert_same true, Cal.session_open?(Time.local(2026, 10, 15, 14, 59, 59))
      assert_same false, Cal.session_open?(Time.local(2026, 10, 15, 15, 0, 0))

      # Friday settle viewed Monday 07:00 ET (06:00 CDT)
      assert_equal d(2026, 10, 16), Cal.latest_session(Time.local(2026, 10, 19, 6, 0))

      assert_equal Time.utc(2026, 10, 15, 20, 0, 0), Cal.close_time(d(2026, 10, 15)).utc
      assert_equal d(2026, 10, 15), Cal.market_date(Time.local(2026, 10, 15, 0, 5))
    end
  end

  test "dst transition dates behave under a chicago host zone" do
    with_tz("America/Chicago") do
      # Chicago and New York share transition dates; their 09:30 NY open is 08:30 CT year round.
      assert_same true, Cal.session_open?(Time.local(2026, 3, 9, 8, 30))
      assert_same false, Cal.session_open?(Time.local(2026, 3, 9, 8, 29))
      assert_same true, Cal.session_open?(Time.local(2026, 11, 2, 8, 30))
      assert_same false, Cal.session_open?(Time.local(2026, 11, 2, 8, 29))
      assert_equal d(2026, 3, 6), Cal.latest_session(Time.local(2026, 3, 8, 12))
      assert_equal d(2026, 10, 30), Cal.latest_session(Time.local(2026, 11, 1, 12))
    end
  end

  test "accepts ActiveSupport time with zone and plain Time interchangeably" do
    utc = Time.utc(2026, 10, 15, 14, 0)
    assert_equal Cal.latest_session(utc), Cal.latest_session(utc.in_time_zone("Asia/Tokyo"))
    assert_equal Cal.session_open?(utc), Cal.session_open?(utc.in_time_zone("Pacific/Auckland"))
    assert_equal Cal.market_date(utc), Cal.market_date(utc.in_time_zone("Asia/Tokyo"))
  end

  test "Time.zone setting of the app does not leak into results" do
    Time.use_zone("Pacific/Auckland") do
      assert_equal d(2026, 10, 16), Cal.market_date(Time.utc(2026, 10, 16, 4, 0))
      assert_equal d(2026, 10, 15), Cal.market_date(Time.utc(2026, 10, 16, 3, 59))
    end
  end
end
