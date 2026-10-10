require "test_helper"

class SecurityFundamentalTest < ActiveSupport::TestCase
  setup { @security = securities(:aapl) }

  test "missing ratings are nil rather than zero" do
    record = SecurityFundamental.new(security: @security, payload: { "trailing_pe" => 30.0 }, fetched_at: Time.current)

    assert_nil record.ratings
    assert_nil record.market_cap
    assert_equal 30.0, record.trailing_pe
  end

  test "ratings and total come from the payload" do
    record = SecurityFundamental.new(security: @security, fetched_at: Time.current,
                                     payload: { "strong_buy" => 6, "buy" => 19, "hold" => 13, "sell" => 3, "strong_sell" => 3 })

    assert_equal 44, record.rating_total
  end

  test "stale after thirty-six hours or when never fetched" do
    assert SecurityFundamental.new(security: @security).stale?
    assert SecurityFundamental.new(security: @security, fetched_at: 37.hours.ago).stale?
    assert_not SecurityFundamental.new(security: @security, fetched_at: 2.hours.ago).stale?
  end

  test "refresh candidates skip fresh data and recent failures but include never-fetched" do
    fresh = securities(:aapl)
    never = securities(:msft)
    SecurityFundamental.create!(security: fresh, payload: { "beta" => 1 }, fetched_at: 1.hour.ago, last_attempt_at: 1.hour.ago)

    assert_equal [ never ], SecurityFundamental.refresh_candidates([ fresh, never ])

    SecurityFundamental.create!(security: never, payload: {}, last_attempt_at: 10.minutes.ago, last_error: "429")
    assert_empty SecurityFundamental.refresh_candidates([ fresh, never ])
  end
end
