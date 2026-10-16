# frozen_string_literal: true

require "test_helper"

# Hostile calendar tests derived only from options-spec-v2 §1.1.
# Expected to NameError until Options::MarketCalendar exists.
module Options
  module Adversarial
  end
end

class Options::Adversarial::MarketCalendarTest < ActiveSupport::TestCase
  NY = "America/New_York"

  def ny_time(year, month, day, hour, min, sec = 0)
    Time.find_zone!(NY).local(year, month, day, hour, min, sec)
  end

  def cal
    Options::MarketCalendar
  end

  # --- holidays 2026 / 2027 (named + observed) ---

  test "2026 full NYSE holiday set includes Good Friday, Thanksgiving, observed Independence Day" do
    hols = cal.holidays(2026)
    assert_kind_of Set, hols
    [
      Date.new(2026, 1, 1),   # New Year's Thursday
      Date.new(2026, 1, 19),  # MLK 3rd Monday
      Date.new(2026, 2, 16),  # Presidents 3rd Monday
      Date.new(2026, 4, 3),   # Good Friday (Easter 2026-04-05)
      Date.new(2026, 5, 25),  # Memorial last Monday May
      Date.new(2026, 6, 19),  # Juneteenth Friday
      Date.new(2026, 7, 3),   # Independence Day Saturday -> observed Friday
      Date.new(2026, 9, 7),   # Labor 1st Monday Sep
      Date.new(2026, 11, 26), # Thanksgiving 4th Thursday
      Date.new(2026, 12, 25)  # Christmas Friday
    ].each do |d|
      assert_includes hols, d, "2026 holidays missing #{d}"
      refute cal.trading_day?(d), "#{d} must not be a trading day"
    end
  end

  test "2027 holidays include Good Friday 2027-03-26, Juneteenth observed Friday, Independence observed Monday, Christmas observed Friday" do
    hols = cal.holidays(2027)
    assert_kind_of Set, hols
    [
      Date.new(2027, 1, 1),
      Date.new(2027, 1, 18),
      Date.new(2027, 2, 15),
      Date.new(2027, 3, 26),  # Good Friday (Easter 2027-03-28)
      Date.new(2027, 5, 31),
      Date.new(2027, 6, 18),  # Juneteenth Saturday 2027-06-19 -> Friday
      Date.new(2027, 7, 5),   # Independence Sunday 2027-07-04 -> Monday
      Date.new(2027, 9, 6),
      Date.new(2027, 11, 25),
      Date.new(2027, 12, 24)  # Christmas Saturday 2027-12-25 -> Friday
    ].each do |d|
      assert_includes hols, d, "2027 holidays missing #{d}"
      refute cal.trading_day?(d), "#{d} must not be a trading day"
    end
  end

  test "Juneteenth 2027-06-19 is Saturday so the observed close is Friday 2027-06-18 not Monday" do
    refute cal.trading_day?(Date.new(2027, 6, 18))
    refute cal.trading_day?(Date.new(2027, 6, 19))
    assert cal.trading_day?(Date.new(2027, 6, 17)) # Thursday
    assert cal.trading_day?(Date.new(2027, 6, 21)) # Monday after
    refute_includes cal.holidays(2027), Date.new(2027, 6, 21)
  end

  test "Independence Day 2026 Saturday is observed Friday 2026-07-03; 2026-07-02 is a trading day" do
    refute cal.trading_day?(Date.new(2026, 7, 3))
    refute cal.trading_day?(Date.new(2026, 7, 4))
    assert cal.trading_day?(Date.new(2026, 7, 2))
    assert cal.trading_day?(Date.new(2026, 7, 6))
  end

  test "New Year's Day on Saturday is NOT observed the prior Friday (2022-01-01 and 2028-01-01)" do
    assert_equal 6, Date.new(2022, 1, 1).wday # Saturday
    assert_equal 6, Date.new(2028, 1, 1).wday
    # Prior Friday is a trading day (spec exception; not a NYSE observed close here).
    assert cal.trading_day?(Date.new(2021, 12, 31)), "2021-12-31 Friday must remain a trading day"
    assert cal.trading_day?(Date.new(2027, 12, 31)), "2027-12-31 Friday must remain a trading day"
    refute_includes cal.holidays(2022), Date.new(2021, 12, 31)
    refute_includes cal.holidays(2028), Date.new(2027, 12, 31)
    refute_includes cal.holidays(2021), Date.new(2021, 12, 31) if cal.respond_to?(:holidays)
  end

  test "weekends are never trading days even when not in the holiday set" do
    refute cal.trading_day?(Date.new(2026, 10, 17)) # Saturday
    refute cal.trading_day?(Date.new(2026, 10, 18)) # Sunday
  end

  test "Thanksgiving Friday is a trading day with an early close" do
    refute cal.trading_day?(Date.new(2026, 11, 26))
    assert cal.trading_day?(Date.new(2026, 11, 27)), "day after Thanksgiving remains a trading day"
    assert cal.early_close?(Date.new(2026, 11, 27))
  end

  # --- market_date ---

  test "market_date is the America/New_York calendar date of now, not UTC date" do
    now = Time.utc(2026, 10, 16, 3, 30, 0) # 2026-10-15 23:30 EDT
    assert_equal Date.new(2026, 10, 15), cal.market_date(now)
    now2 = Time.utc(2026, 10, 16, 4, 0, 0) # 2026-10-16 00:00 EDT
    assert_equal Date.new(2026, 10, 16), cal.market_date(now2)
  end

  # --- DST edges 2026-03-08 spring-forward and 2026-11-01 fall-back ---

  test "DST spring-forward 2026-03-08: Monday open is 09:30 EDT = 13:30 UTC not 14:30" do
    # Friday 2026-03-06 is still EST: 09:30 ET = 14:30 UTC
    fri_open = Time.utc(2026, 3, 6, 14, 30, 0)
    assert cal.session_open?(fri_open)
    refute cal.session_open?(Time.utc(2026, 3, 6, 14, 29, 0))

    # Monday 2026-03-09 is EDT: 09:30 ET = 13:30 UTC
    mon_open = Time.utc(2026, 3, 9, 13, 30, 0)
    assert_equal Date.new(2026, 3, 9), cal.market_date(mon_open)
    assert cal.session_open?(mon_open)
    refute cal.session_open?(Time.utc(2026, 3, 9, 13, 29, 0)), "09:29 EDT is not open"
    # 14:30 UTC Monday is 10:30 EDT — open, not the EST mapping
    assert cal.session_open?(Time.utc(2026, 3, 9, 14, 30, 0))
    assert_equal Date.new(2026, 3, 9), cal.latest_session(mon_open)
  end

  test "DST fall-back 2026-11-01: Monday open is 09:30 EST = 14:30 UTC not 13:30" do
    # Friday 2026-10-30 still EDT: 09:30 ET = 13:30 UTC
    assert cal.session_open?(Time.utc(2026, 10, 30, 13, 30, 0))
    refute cal.session_open?(Time.utc(2026, 10, 30, 13, 29, 0))

    # Monday 2026-11-02 EST: 09:30 ET = 14:30 UTC
    refute cal.session_open?(Time.utc(2026, 11, 2, 13, 30, 0)), "08:30 EST is not open"
    assert cal.session_open?(Time.utc(2026, 11, 2, 14, 30, 0))
    refute cal.session_open?(Time.utc(2026, 11, 2, 14, 29, 0))
    assert_equal Date.new(2026, 11, 2), cal.latest_session(Time.utc(2026, 11, 2, 14, 30, 0))
  end

  # --- session_open? edge minutes ---

  test "session_open? is half-open 09:30 inclusive and 16:00 exclusive in NY time" do
    day = [2026, 10, 15] # Thursday
    refute cal.session_open?(ny_time(*day, 9, 29, 59))
    assert cal.session_open?(ny_time(*day, 9, 30, 0))
    assert cal.session_open?(ny_time(*day, 15, 59, 59))
    refute cal.session_open?(ny_time(*day, 16, 0, 0))
    refute cal.session_open?(ny_time(*day, 16, 0, 1))
    refute cal.session_open?(ny_time(*day, 8, 0, 0))
    refute cal.session_open?(ny_time(*day, 20, 0, 0))
  end

  test "session_open? is false on weekends and holidays even at 10:00 ET" do
    refute cal.session_open?(ny_time(2026, 10, 17, 10, 0)) # Saturday
    refute cal.session_open?(ny_time(2026, 10, 18, 10, 0)) # Sunday
    refute cal.session_open?(ny_time(2026, 4, 3, 10, 0))   # Good Friday
    refute cal.session_open?(ny_time(2026, 1, 19, 10, 0))  # MLK
  end

  # --- latest_session ---

  test "latest_session Friday 21:00 UTC is that Friday (after the 09:30 open, after the 16:00 close)" do
    now = Time.utc(2026, 10, 16, 21, 0, 0) # Friday 17:00 EDT
    assert_equal Date.new(2026, 10, 16), cal.latest_session(now)
    refute cal.session_open?(now)
  end

  test "latest_session Saturday and Sunday resolve to the previous Friday" do
    assert_equal Date.new(2026, 10, 16), cal.latest_session(Time.utc(2026, 10, 17, 16, 0, 0))
    assert_equal Date.new(2026, 10, 16), cal.latest_session(Time.utc(2026, 10, 18, 16, 0, 0))
    assert_equal Date.new(2026, 10, 16), cal.latest_session(ny_time(2026, 10, 18, 23, 59))
  end

  test "latest_session Monday 13:00 UTC (09:00 ET during EDT, before open) is previous Friday" do
    now = Time.utc(2026, 10, 19, 13, 0, 0)
    assert_equal Date.new(2026, 10, 16), cal.latest_session(now)
    refute cal.session_open?(now)
  end

  test "latest_session Monday 14:00 UTC during EDT is that Monday (10:00 ET, after open)" do
    now = Time.utc(2026, 10, 19, 14, 0, 0)
    assert_equal Date.new(2026, 10, 19), cal.latest_session(now)
    assert cal.session_open?(now)
  end

  test "latest_session after-hours on a trading day stays that day" do
    now = ny_time(2026, 10, 16, 16, 30)
    assert_equal Date.new(2026, 10, 16), cal.latest_session(now)
    refute cal.session_open?(now)
  end

  test "latest_session on a holiday Monday is the previous Friday" do
    # MLK Monday 2026-01-19
    assert_equal Date.new(2026, 1, 16), cal.latest_session(ny_time(2026, 1, 19, 10, 0))
    assert_equal Date.new(2026, 1, 16), cal.latest_session(ny_time(2026, 1, 19, 15, 0))
    assert_equal Date.new(2026, 1, 16), cal.latest_session(Time.utc(2026, 1, 19, 20, 0, 0))
  end

  test "latest_session on Good Friday is the previous Thursday" do
    assert_equal Date.new(2026, 4, 2), cal.latest_session(ny_time(2026, 4, 3, 12, 0))
    assert_equal Date.new(2026, 4, 2), cal.latest_session(ny_time(2026, 4, 4, 12, 0)) # Saturday
  end

  test "latest_session Friday 09:29 ET is still the previous session" do
    assert_equal Date.new(2026, 10, 15), cal.latest_session(ny_time(2026, 10, 16, 9, 29))
    assert_equal Date.new(2026, 10, 16), cal.latest_session(ny_time(2026, 10, 16, 9, 30))
  end

  test "latest_session on Juneteenth observed Friday 2027-06-18 is Thursday 2027-06-17" do
    assert_equal Date.new(2027, 6, 17), cal.latest_session(ny_time(2027, 6, 18, 12, 0))
    assert_equal Date.new(2027, 6, 17), cal.latest_session(ny_time(2027, 6, 19, 12, 0))
  end

  # --- trading_days_between half-open (from, to] ---

  test "trading_days_between is half-open (from, to] and 0 when to <= from" do
    assert_equal 0, cal.trading_days_between(Date.new(2026, 10, 15), Date.new(2026, 10, 15))
    assert_equal 0, cal.trading_days_between(Date.new(2026, 10, 16), Date.new(2026, 10, 15))
    assert_equal 0, cal.trading_days_between(Date.new(2026, 10, 16), Date.new(2026, 10, 16))
    # Thursday -> Friday includes Friday only
    assert_equal 1, cal.trading_days_between(Date.new(2026, 10, 15), Date.new(2026, 10, 16))
    # Friday -> Monday includes Monday only
    assert_equal 1, cal.trading_days_between(Date.new(2026, 10, 16), Date.new(2026, 10, 19))
    # Thursday -> Monday includes Friday and Monday
    assert_equal 2, cal.trading_days_between(Date.new(2026, 10, 15), Date.new(2026, 10, 19))
  end

  test "trading_days_between skips Good Friday and the weekend" do
    # (2026-04-02, 2026-04-06] = Monday only
    assert_equal 1, cal.trading_days_between(Date.new(2026, 4, 2), Date.new(2026, 4, 6))
    assert_equal 0, cal.trading_days_between(Date.new(2026, 4, 2), Date.new(2026, 4, 3))
    assert_equal 0, cal.trading_days_between(Date.new(2026, 4, 2), Date.new(2026, 4, 5))
  end

  test "trading_days_between across Thanksgiving is 1 from Wednesday to Friday" do
    # (2026-11-25, 2026-11-27] = Friday only (Thursday holiday)
    assert_equal 1, cal.trading_days_between(Date.new(2026, 11, 25), Date.new(2026, 11, 27))
  end

  # --- previous_session / close_time ---

  test "previous_session is the trading day strictly before date" do
    assert_equal Date.new(2026, 10, 15), cal.previous_session(Date.new(2026, 10, 16))
    assert_equal Date.new(2026, 10, 16), cal.previous_session(Date.new(2026, 10, 19))
    assert_equal Date.new(2026, 10, 16), cal.previous_session(Date.new(2026, 10, 17)) # Saturday
    assert_equal Date.new(2026, 1, 16), cal.previous_session(Date.new(2026, 1, 19)) # MLK
    assert_equal Date.new(2026, 4, 2), cal.previous_session(Date.new(2026, 4, 6))
    assert_equal Date.new(2026, 7, 2), cal.previous_session(Date.new(2026, 7, 6))
  end

  test "close_time models supported NYSE early closes and retains 16:00 otherwise" do
    thanksgiving_friday = cal.close_time(Date.new(2026, 11, 27))
    assert_equal Time.find_zone!(NY).local(2026, 11, 27, 13, 0, 0), thanksgiving_friday.in_time_zone(NY)
    refute cal.early_close?(Date.new(2026, 7, 3)), "observed Independence Day is fully closed, not early"
    normal = cal.close_time(Date.new(2026, 11, 13))
    assert_equal Time.find_zone!(NY).local(2026, 11, 13, 16, 0, 0), normal.in_time_zone(NY)
  end

  test "latest_session is NY-based even when process TZ is America/Chicago" do
    old = ENV["TZ"]
    ENV["TZ"] = "America/Chicago"
    begin
      now = Time.utc(2026, 10, 19, 13, 0, 0) # 08:00 CDT / 09:00 EDT, before open
      assert_equal Date.new(2026, 10, 16), cal.latest_session(now)
      assert_equal Date.new(2026, 10, 15), cal.market_date(Time.utc(2026, 10, 16, 3, 30, 0))
    ensure
      ENV["TZ"] = old
    end
  end
end
