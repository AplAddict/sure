require "test_helper"

class InvestmentAllocationTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    # Isolate from the fixture family's own positions.
    Holding.where(account_id: @family.accounts.select(:id)).delete_all
    @account = @family.accounts.create!(name: "Alloc #{SecureRandom.hex(3)}", balance: 300, cash_balance: 0, currency: "USD", owner: @user, accountable: Investment.new)
    @a = Security.create!(ticker: "ALA#{SecureRandom.hex(2).upcase}", name: "A", sector: "Technology", country_code: "US", asset_class: "equity")
    @b = Security.create!(ticker: "ALB#{SecureRandom.hex(2).upcase}", name: "B", sector: "Health Care", country_code: "CA", asset_class: "equity")
    @c = Security.create!(ticker: "ALC#{SecureRandom.hex(2).upcase}", name: "C")
    [ [ @a, 200 ], [ @b, 100 ], [ @c, 100 ] ].each do |security, amount|
      Holding.create!(account: @account, security: security, date: Date.current, qty: 1, price: amount, amount: amount, currency: "USD", cost_basis: amount / 2.0)
    end
  end

  test "groups by sector with an explicit Unclassified bucket that sums to the total" do
    allocation = InvestmentAllocation.new(user: @user, by: "sector")

    segments = allocation.segments.index_by(&:label)
    assert_equal 200, segments["Technology"].amount.to_i
    assert_equal 100, segments["Health Care"].amount.to_i
    assert_equal 100, segments[InvestmentAllocation::UNCLASSIFIED].amount.to_i
    assert_equal 400, allocation.total.to_i
    assert_in_delta 50.0, segments["Technology"].weight, 0.001
    assert_in_delta 100.0, allocation.segments.sum(&:weight), 0.001
  end

  test "groups by country, asset class, account, currency and security" do
    assert_equal %w[CA US] + [ InvestmentAllocation::UNCLASSIFIED ], InvestmentAllocation.new(user: @user, by: "country").segments.map(&:label).sort
    assert_equal 2, InvestmentAllocation.new(user: @user, by: "asset_class").segments.size
    assert_equal [ @account.name ], InvestmentAllocation.new(user: @user, by: "account").segments.map(&:label)
    assert_equal [ "USD" ], InvestmentAllocation.new(user: @user, by: "currency").segments.map(&:label)
    assert_equal 3, InvestmentAllocation.new(user: @user, by: "security").segments.size
  end

  test "an unknown grouping falls back to security" do
    assert_equal "security", InvestmentAllocation.new(user: @user, by: "../../etc").by
  end

  test "holdings in a currency with no exchange rate are excluded and reported, never counted 1:1" do
    foreign = @family.accounts.create!(name: "EUR #{SecureRandom.hex(3)}", balance: 50, cash_balance: 0, currency: "EUR", owner: @user, accountable: Investment.new)
    Holding.create!(account: foreign, security: @c, date: Date.current, qty: 1, price: 50, amount: 50, currency: "EUR")

    allocation = InvestmentAllocation.new(user: @user, by: "currency")

    assert_equal 400, allocation.total.to_i
    assert_equal 1, allocation.excluded_count
    assert_equal [ "EUR" ], allocation.missing_rates
  end

  test "never includes accounts the user cannot access" do
    assert_empty InvestmentAllocation.new(user: users(:empty), by: "security").segments
  end

  test "data quality lists missing cost basis and stale prices, scoped to the user" do
    Holding.where(security: @c).update_all(cost_basis: nil)
    stale = Security.create!(ticker: "STL#{SecureRandom.hex(2).upcase}", name: "Stale")
    Holding.create!(account: @account, security: stale, date: Date.current, qty: 1, price: 5, amount: 5, currency: "USD", cost_basis: 5)
    Security::Price.create!(security: stale, date: 30.days.ago.to_date, price: 5, currency: "USD")

    issues = InvestmentAllocation.new(user: @user, by: "security").data_quality

    assert_includes issues.select { |i| i.kind == :missing_cost_basis }.map { |i| i.security.id }, @c.id
    assert_includes issues.select { |i| i.kind == :stale_price }.map { |i| i.security.id }, stale.id
    assert_empty InvestmentAllocation.new(user: users(:empty), by: "security").data_quality
  end
end
