require "test_helper"

class InvestmentsHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "a measured zero renders as money, only nil is unavailable" do
    assert_includes investment_money(BigDecimal("0"), "USD"), "$0.00"
    assert_includes investment_money(nil, "USD"), "—"
    assert_includes investment_money(BigDecimal("5"), "USD"), "privacy-sensitive"
  end

  test "gain carries an explicit sign and tone so colour is not the only signal" do
    up = investment_gain(BigDecimal("12.5"), "USD", percent: BigDecimal("5"))
    down = investment_gain(BigDecimal("-12.5"), "USD", percent: BigDecimal("-5"))
    flat = investment_gain(BigDecimal("0"), "USD")

    assert_includes up, "+$12.50"
    assert_includes up, "text-success"
    assert_includes up, "(+5.0%)"
    assert_includes down, "text-destructive"
    assert_not_includes down, "+$"
    assert_includes flat, "text-primary"
    assert_includes investment_gain(nil, "USD"), "—"
  end

  test "a missing percentage is omitted rather than shown as zero" do
    assert_not_includes investment_gain(BigDecimal("10"), "USD", percent: nil), "%"
  end

  test "quantities are privacy masked and unavailable when nil" do
    assert_includes investment_quantity(BigDecimal("1.50000000")), "privacy-sensitive"
    assert_includes investment_quantity(BigDecimal("1.50000000")), ">1.5<"
    assert_includes investment_quantity(nil), "—"
  end

  test "freshness maps to real design-system tones" do
    assert_includes freshness_pill("current"), "Current"
    assert_includes freshness_pill("stale"), "Stale"
    assert_includes freshness_pill("unavailable"), "Unavailable"
  end

  test "stat tile includes the hint only when given" do
    assert_includes investment_stat("Label", "Value", hint: "Why"), "Why"
    assert_not_includes investment_stat("Label", "Value"), "text-xs"
  end
end
