require "test_helper"

class Security::FundamentalsRefresherTest < ActiveSupport::TestCase
  setup do
    @security = securities(:aapl)
    @provider = mock
  end

  def response(success:, data: nil, message: nil)
    Provider::Response.new(success?: success, data: data, error: message && StandardError.new(message))
  end

  test "stores fetched data with its timestamp" do
    @provider.expects(:fetch_security_fundamentals).returns(response(success: true, data: { "trailing_pe" => 31.5, "market_cap" => nil }))

    assert_equal :ok, Security::FundamentalsRefresher.new(provider: @provider, pause: 0).refresh(@security)

    record = @security.reload.fundamental
    assert_equal 31.5, record.trailing_pe
    assert_nil record.market_cap
    assert record.fetched_at.present?
    assert_nil record.last_error
  end

  test "a failure keeps the previous good data and records the error" do
    SecurityFundamental.create!(security: @security, payload: { "trailing_pe" => 20.0 }, fetched_at: 2.days.ago)
    @provider.expects(:fetch_security_fundamentals).returns(response(success: false, message: "boom"))

    assert_equal :failed, Security::FundamentalsRefresher.new(provider: @provider, pause: 0).refresh(@security)

    record = @security.reload.fundamental
    assert_equal 20.0, record.trailing_pe
    assert_in_delta 2.days.ago.to_f, record.fetched_at.to_f, 5
    assert_equal "boom", record.last_error
  end

  test "a rate limit is reported distinctly" do
    @provider.expects(:fetch_security_fundamentals).returns(response(success: false, message: "Yahoo Finance rate limit (429)"))

    assert_equal :rate_limited, Security::FundamentalsRefresher.new(provider: @provider, pause: 0).refresh(@security)
  end

  test "refresh_all stops at the first rate limit" do
    Security::FundamentalsRefresher.stubs(:held_securities).returns([ securities(:aapl), securities(:msft) ])
    @provider.expects(:fetch_security_fundamentals).once.returns(response(success: false, message: "429 too many requests"))

    result = Security::FundamentalsRefresher.new(provider: @provider, pause: 0).refresh_all

    assert result.skipped_for_rate_limit
    assert_equal 0, result.refreshed
  end
end
