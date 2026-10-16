require "test_helper"

class OptionsTest < ActiveSupport::TestCase
  def with_rate_env(value)
    original = ENV["OPTIONS_RISK_FREE_RATE"]
    value.nil? ? ENV.delete("OPTIONS_RISK_FREE_RATE") : ENV["OPTIONS_RISK_FREE_RATE"] = value
    yield
  ensure
    original.nil? ? ENV.delete("OPTIONS_RISK_FREE_RATE") : ENV["OPTIONS_RISK_FREE_RATE"] = original
  end

  test "risk free rate defaults to 0.04 when env is unset or blank" do
    with_rate_env(nil) { assert_equal 0.04, Options.risk_free_rate }
    with_rate_env("") { assert_equal 0.04, Options.risk_free_rate }
    with_rate_env("  ") { assert_equal 0.04, Options.risk_free_rate }
  end

  test "risk free rate parses a valid env value as Float" do
    with_rate_env("0.035") do
      assert_kind_of Float, Options.risk_free_rate
      assert_in_delta 0.035, Options.risk_free_rate, 1e-12
    end
  end

  test "zero and the 0.2 upper bound are valid" do
    with_rate_env("0") { assert_equal 0.0, Options.risk_free_rate }
    with_rate_env("0.2") { assert_in_delta 0.2, Options.risk_free_rate, 1e-12 }
  end

  test "invalid, negative, too large or non-finite env values fall back to default" do
    [ "abc", "-0.01", "0.21", "5", "NaN", "Infinity", "0.04x" ].each do |bad|
      with_rate_env(bad) { assert_equal 0.04, Options.risk_free_rate, "expected fallback for #{bad.inspect}" }
    end
  end
end
