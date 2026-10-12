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

  test "sector grouping looks through a fund using its reported sector weights, with the rest shown as not reported" do
    fund = Security.create!(ticker: "ALF#{SecureRandom.hex(2).upcase}", name: "Fund", asset_class: "equity", asset_sub_class: "etf")
    SecurityFundamental.create!(security: fund, fetched_at: 1.hour.ago, payload: { "fund_sectors" => { "Technology" => 0.5, "Health Care" => 0.3 }, "fund_mix" => { "stock" => 1.0 } })
    Holding.create!(account: @account, security: fund, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD", cost_basis: 50)

    segments = InvestmentAllocation.new(user: @user, by: "sector").segments.index_by(&:label)

    assert_equal 250, segments["Technology"].amount.to_i      # 200 stock + 50 from the fund
    assert_equal 130, segments["Health Care"].amount.to_i     # 100 stock + 30 from the fund
    assert_equal 20, segments[InvestmentAllocation::FUND_UNREPORTED].amount.to_i
    assert_equal 100, segments[InvestmentAllocation::UNCLASSIFIED].amount.to_i
    assert_in_delta 100.0, InvestmentAllocation.new(user: @user, by: "sector").segments.sum(&:weight), 0.001
  end

  test "a fund with no reported sector weights stays one Unclassified block, never spread" do
    fund = Security.create!(ticker: "ALG#{SecureRandom.hex(2).upcase}", name: "Fund", asset_sub_class: "etf")
    Holding.create!(account: @account, security: fund, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD", cost_basis: 50)

    segments = InvestmentAllocation.new(user: @user, by: "sector").segments.index_by(&:label)

    assert_equal 200, segments[InvestmentAllocation::UNCLASSIFIED].amount.to_i
    assert_nil segments[InvestmentAllocation::FUND_UNREPORTED]
  end

  test "weights that add up to more than the fund are not trusted" do
    fund = Security.create!(ticker: "ALH#{SecureRandom.hex(2).upcase}", name: "Fund", asset_sub_class: "etf")
    SecurityFundamental.create!(security: fund, fetched_at: 1.hour.ago, payload: { "fund_sectors" => { "Technology" => 0.9, "Health Care" => 0.4 } })
    Holding.create!(account: @account, security: fund, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD", cost_basis: 50)

    segments = InvestmentAllocation.new(user: @user, by: "sector").segments.index_by(&:label)

    assert_equal 200, segments[InvestmentAllocation::UNCLASSIFIED].amount.to_i
  end

  test "asset class looks through a fund by its reported stock, bond and cash mix" do
    fund = Security.create!(ticker: "ALI#{SecureRandom.hex(2).upcase}", name: "Balanced", asset_sub_class: "etf")
    SecurityFundamental.create!(security: fund, fetched_at: 1.hour.ago, payload: { "fund_mix" => { "stock" => 0.6, "bond" => 0.3, "cash" => 0.1 } })
    Holding.create!(account: @account, security: fund, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD", cost_basis: 50)

    segments = InvestmentAllocation.new(user: @user, by: "asset_class").segments.index_by(&:label)

    assert_equal 360, segments["Equity"].amount.to_i          # 300 stock + 60 from the fund
    assert_equal 30, segments["Fixed Income"].amount.to_i
    assert_equal 10, segments["Liquidity"].amount.to_i
  end

  test "look-through never reads another family's fund data" do
    outsider = Security.create!(ticker: "ALJ#{SecureRandom.hex(2).upcase}", name: "Fund", asset_sub_class: "etf")
    SecurityFundamental.create!(security: outsider, fetched_at: 1.hour.ago, payload: { "fund_sectors" => { "Energy" => 1.0 } })

    assert_nil InvestmentAllocation.new(user: users(:empty), by: "sector").segments.find { |s| s.label == "Energy" }
  end
end
