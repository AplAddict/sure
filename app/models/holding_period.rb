# The one place that decides whether a lot has been held long enough to be
# "long-term": held MORE than one year, counted by calendar anniversary rather
# than a fixed 365 days (a span containing Feb 29 is 366 days and a fixed count
# would flip a day early). The anniversary date itself is still short-term.
#
# This is date arithmetic only. It does not know a jurisdiction or a tax rule;
# callers present the result as a holding period, never as a tax determination.
module HoldingPeriod
  module_function

  # nil when the date is missing or in the future (no meaningful period).
  def long_term?(acquired_on, today)
    return nil if acquired_on.nil? || acquired_on > today

    today > acquired_on.next_year
  end

  # Days until a short-term lot first counts as long-term (>= 1), or nil when
  # it already is, or the date is unusable.
  def days_to_long_term(acquired_on, today)
    return nil unless long_term?(acquired_on, today) == false

    (acquired_on.next_year - today).to_i + 1
  end
end
