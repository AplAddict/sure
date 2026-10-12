require "test_helper"

class Security::IntradayPriceRefresherTest < ActiveSupport::TestCase
  Quote = Struct.new(:date, :price, :currency, keyword_init: true)

  setup do
    travel_to Time.utc(2026, 10, 12, 15, 0) # 11:00 ET, market open
    # Isolate from fixture positions in other families.
    Holding.delete_all
    @account = families(:empty).accounts.create!(name: "Live #{SecureRandom.hex(3)}", balance: 100, cash_balance: 0, currency: "USD", accountable: Investment.new)
    @security = Security.create!(ticker: "LIV#{SecureRandom.hex(2).upcase}", name: "Live")
    Holding.create!(account: @account, security: @security, date: Date.current, qty: 2, price: 100, amount: 200, currency: "USD")
    Security::Price.create!(security: @security, date: Date.new(2026, 10, 9), price: 100, currency: "USD", provisional: false)
    Security::Price.create!(security: @security, date: Date.new(2026, 10, 12), price: 100, currency: "USD", provisional: true)
    @provider = mock("provider")
    Security.any_instance.stubs(:price_data_provider).returns(@provider)
  end

  teardown { travel_back }

  def respond_with(*quotes)
    Provider::Response.new(success?: true, data: quotes, error: nil)
  end

  test "writes today's live price as a provisional row" do
    @provider.stubs(:fetch_security_prices).returns(respond_with(Quote.new(date: Date.new(2026, 10, 12), price: 104.5, currency: "USD")))

    result = Security::IntradayPriceRefresher.new.refresh

    row = Security::Price.find_by(security: @security, date: Date.new(2026, 10, 12))
    assert_equal BigDecimal("104.5"), row.price
    assert row.provisional, "the nightly close import must still replace it"
    assert_equal 1, result.updated
  end

  test "never touches a final or user-entered price" do
    Security::Price.where(security: @security, date: Date.new(2026, 10, 12)).update_all(provisional: false, price: 99)
    @provider.stubs(:fetch_security_prices).returns(respond_with(Quote.new(date: Date.new(2026, 10, 12), price: 104.5, currency: "USD")))

    Security::IntradayPriceRefresher.new.refresh

    assert_equal BigDecimal("99"), Security::Price.find_by(security: @security, date: Date.new(2026, 10, 12)).price
  end

  test "does nothing outside market hours" do
    travel_to Time.utc(2026, 10, 12, 12, 0) # 08:00 ET
    @provider.expects(:fetch_security_prices).never

    assert_equal 0, Security::IntradayPriceRefresher.new.refresh.updated
  end

  test "does nothing on a weekend" do
    travel_to Time.utc(2026, 10, 11, 16, 0)
    @provider.expects(:fetch_security_prices).never

    assert_equal 0, Security::IntradayPriceRefresher.new.refresh.updated
  end

  test "ignores a provider row that is not for today (market closed that day)" do
    @provider.stubs(:fetch_security_prices).returns(respond_with(Quote.new(date: Date.new(2026, 10, 9), price: 101, currency: "USD")))

    assert_equal 0, Security::IntradayPriceRefresher.new.refresh.updated
    assert_equal BigDecimal("100"), Security::Price.find_by(security: @security, date: Date.new(2026, 10, 12)).price
  end

  test "ignores a price in a different currency than the stored one" do
    @provider.stubs(:fetch_security_prices).returns(respond_with(Quote.new(date: Date.new(2026, 10, 12), price: 104.5, currency: "EUR")))

    assert_equal 0, Security::IntradayPriceRefresher.new.refresh.updated
  end

  test "ignores zero and missing prices" do
    @provider.stubs(:fetch_security_prices).returns(respond_with(Quote.new(date: Date.new(2026, 10, 12), price: 0, currency: "USD")))

    assert_equal 0, Security::IntradayPriceRefresher.new.refresh.updated
  end

  test "stops at the first provider failure so a rate limit is not hammered" do
    other = Security.create!(ticker: "LV2#{SecureRandom.hex(2).upcase}", name: "Other")
    Holding.create!(account: @account, security: other, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    Security::Price.create!(security: other, date: Date.new(2026, 10, 12), price: 10, currency: "USD", provisional: true)
    Security::Price.create!(security: other, date: Date.new(2026, 10, 9), price: 10, currency: "USD", provisional: false)
    failure = Provider::Response.new(success?: false, data: nil, error: StandardError.new("Yahoo Finance rate limit (429)"))
    @provider.expects(:fetch_security_prices).once.returns(failure)

    result = Security::IntradayPriceRefresher.new.refresh

    assert result.rate_limited
    assert_equal 0, result.updated
  end

  test "only refreshes securities that are currently held" do
    unheld = Security.create!(ticker: "UNH#{SecureRandom.hex(2).upcase}", name: "Unheld")
    Security::Price.create!(security: unheld, date: Date.new(2026, 10, 12), price: 5, currency: "USD", provisional: true)
    @provider.expects(:fetch_security_prices).with { |args| args[:symbol] == @security.ticker }.returns(respond_with(Quote.new(date: Date.new(2026, 10, 12), price: 101, currency: "USD")))

    Security::IntradayPriceRefresher.new.refresh

    assert_equal BigDecimal("5"), Security::Price.find_by(security: unheld, date: Date.new(2026, 10, 12)).price
  end
end
