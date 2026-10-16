# NYSE trading calendar for the options feature. Pure: no DB, no network, independent of the host TZ
# and of Time.zone. Every "today" / "latest session" in this feature is derived here, never from Date.current.
#
# Early closes are modelled from the documented recurring NYSE schedule: the day after
# Thanksgiving, Christmas Eve, and July 3 when each is a trading day. Full closures
# always win (for example, observed Independence Day on July 3 2026 and observed
# Christmas on December 24 2027).
module Options::MarketCalendar
  ZONE_NAME = "America/New_York".freeze
  OPEN_MINUTES = 9 * 60 + 30
  REGULAR_CLOSE_MINUTES = 16 * 60
  EARLY_CLOSE_MINUTES = 13 * 60

  @holidays_by_year = {}
  @mutex = Mutex.new

  module_function

  # NY calendar date of `now`.
  def market_date(now)
    localize(now).to_date
  end

  def trading_day?(date)
    date = date.to_date
    return false if date.saturday? || date.sunday?

    !holidays(date.year).include?(date)
  end

  # Set of dates in `year` on which the NYSE is closed for a full day (observed dates, not nominal ones).
  def holidays(year)
    year = Integer(year)
    cached = @holidays_by_year[year]
    return cached if cached

    @mutex.synchronize { @holidays_by_year[year] ||= build_holidays(year) }
  end

  # Most recent trading date whose 09:30 ET open has occurred at or before `now`.
  def latest_session(now)
    local = localize(now)
    date = local.to_date
    return date if trading_day?(date) && minutes_of_day(local) >= OPEN_MINUTES

    previous_session(date)
  end

  def session_open?(now)
    local = localize(now)
    return false unless trading_day?(local.to_date)

    minutes_of_day(local) >= OPEN_MINUTES && local < close_time(local.to_date)
  end

  # True for the recurring NYSE 13:00 ET closes that are otherwise trading days.
  def early_close?(date)
    date = date.to_date
    return false unless trading_day?(date)

    date == thanksgiving_friday(date.year) ||
      (date.month == 12 && date.day == 24) ||
      (date.month == 7 && date.day == 3)
  end

  # Number of trading days in the half-open range (from, to]; 0 when to <= from.
  def trading_days_between(from, to)
    from = from.to_date
    to = to.to_date
    return 0 if to <= from

    ((from + 1)..to).count { |date| trading_day?(date) }
  end

  # Previous trading day strictly before `date`.
  def previous_session(date)
    candidate = date.to_date - 1
    candidate -= 1 until trading_day?(candidate)
    candidate
  end

  # 13:00 ET on supported early-close days, otherwise 16:00 ET.
  def close_time(date)
    date = date.to_date
    minutes = early_close?(date) ? EARLY_CLOSE_MINUTES : REGULAR_CLOSE_MINUTES
    hour, minute = minutes.divmod(60)
    zone.local(date.year, date.month, date.day, hour, minute, 0)
  end

  def zone
    ActiveSupport::TimeZone[ZONE_NAME]
  end

  def localize(now)
    now.in_time_zone(zone)
  end

  def minutes_of_day(local)
    local.hour * 60 + local.min
  end

  def build_holidays(year)
    days = [
      observed(Date.new(year, 1, 1), saturday: false),
      nth_weekday(year, 1, 1, 3),
      nth_weekday(year, 2, 1, 3),
      easter(year) - 2,
      last_weekday(year, 5, 1),
      observed(Date.new(year, 6, 19)),
      observed(Date.new(year, 7, 4)),
      nth_weekday(year, 9, 1, 1),
      nth_weekday(year, 11, 4, 4),
      observed(Date.new(year, 12, 25))
    ]
    days.compact.to_set.freeze
  end

  # Saturday -> prior Friday, Sunday -> following Monday. New Year's on a Saturday is not observed.
  def observed(date, saturday: true)
    return date - 1 if date.saturday? && saturday
    return nil if date.saturday?
    return date + 1 if date.sunday?

    date
  end

  def nth_weekday(year, month, wday, n)
    first = Date.new(year, month, 1)
    first + ((wday - first.wday) % 7) + 7 * (n - 1)
  end

  def last_weekday(year, month, wday)
    last = Date.new(year, month, -1)
    last - ((last.wday - wday) % 7)
  end

  def thanksgiving_friday(year)
    nth_weekday(year, 11, 4, 4) + 1
  end

  # Anonymous Gregorian algorithm (Meeus/Jones/Butcher).
  def easter(year)
    a = year % 19
    b, c = year.divmod(100)
    d, e = b.divmod(4)
    f = (b + 8) / 25
    g = (b - f + 1) / 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = c.divmod(4)
    l = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * l) / 451
    month, day = (h + l - 7 * m + 114).divmod(31)
    Date.new(year, month, day + 1)
  end
  private_class_method :zone, :localize, :minutes_of_day, :build_holidays, :observed, :nth_weekday, :last_weekday, :thanksgiving_friday, :easter
end
