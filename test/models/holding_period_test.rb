require "test_helper"

class HoldingPeriodTest < ActiveSupport::TestCase
  test "the anniversary date is still short-term and the day after is long-term" do
    assert_equal false, HoldingPeriod.long_term?(Date.new(2025, 1, 15), Date.new(2026, 1, 15))
    assert_equal true, HoldingPeriod.long_term?(Date.new(2025, 1, 15), Date.new(2026, 1, 16))
  end

  test "a span that contains Feb 29 is judged by anniversary, not by 365 days" do
    assert_equal false, HoldingPeriod.long_term?(Date.new(2023, 3, 1), Date.new(2024, 3, 1))
    assert_equal true, HoldingPeriod.long_term?(Date.new(2023, 3, 1), Date.new(2024, 3, 2))
  end

  test "a Feb 29 acquisition uses Feb 28 as its anniversary in a non-leap year" do
    assert_equal false, HoldingPeriod.long_term?(Date.new(2024, 2, 29), Date.new(2025, 2, 28))
    assert_equal true, HoldingPeriod.long_term?(Date.new(2024, 2, 29), Date.new(2025, 3, 1))
  end

  test "missing or future dates have no holding period" do
    assert_nil HoldingPeriod.long_term?(nil, Date.new(2026, 1, 1))
    assert_nil HoldingPeriod.long_term?(Date.new(2026, 2, 1), Date.new(2026, 1, 1))
    assert_nil HoldingPeriod.days_to_long_term(nil, Date.new(2026, 1, 1))
  end

  test "days to long-term counts down to the first long-term day" do
    assert_equal 1, HoldingPeriod.days_to_long_term(Date.new(2025, 1, 15), Date.new(2026, 1, 15))
    assert_equal 17, HoldingPeriod.days_to_long_term(Date.new(2025, 10, 28), Date.new(2026, 10, 12))  # anniversary is 16 days away; the next day is the first long-term day
    assert_nil HoldingPeriod.days_to_long_term(Date.new(2025, 1, 15), Date.new(2026, 1, 16))
  end
end
