require "test_helper"

class PhysicalMetalTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
  end

  test "only accepts gold or silver and positive troy ounces" do
    metal = PhysicalMetal.new(metal_type: "platinum", troy_ounces: 0, storage_label: "Home safe")

    assert_not metal.valid?
    assert_includes metal.errors[:metal_type], "is not included in the list"
    assert_includes metal.errors[:troy_ounces], "must be greater than 0"
  end

  test "rejects an exact address as a storage label" do
    metal = PhysicalMetal.new(metal_type: "gold", troy_ounces: 1, storage_label: "123 Main Street")

    assert_not metal.valid?
    assert_includes metal.errors[:storage_label], "must be a privacy-safe label, not an address"
  end

  test "is unpriced until a complete manual valuation is provided" do
    metal = PhysicalMetal.new(metal_type: "gold", troy_ounces: 2.5, storage_label: "Home safe")

    assert metal.valid?
    assert metal.unpriced?
    assert_nil metal.manual_valuation_total

    metal.assign_attributes(
      manual_price_per_troy_ounce: 2400,
      valuation_source: "Dealer quote",
      valuation_date: Date.current
    )

    assert metal.valid?
    assert metal.manually_valued?
    assert_equal 6000, metal.manual_valuation_total
  end

  test "rejects incomplete or nonpositive manual valuations" do
    metal = PhysicalMetal.new(
      metal_type: "silver",
      troy_ounces: 10,
      storage_label: "Safe deposit box",
      manual_price_per_troy_ounce: 0,
      valuation_source: "Dealer quote"
    )

    assert_not metal.valid?
    assert_includes metal.errors[:manual_price_per_troy_ounce], "must be greater than 0"
    assert_includes metal.errors[:valuation_date], "can't be blank"
  end

  test "uses Yahoo futures symbols for auto-pricing" do
    assert_equal "SI=F", PhysicalMetal.new(metal_type: "silver").yahoo_price_symbol
    assert_equal "GC=F", PhysicalMetal.new(metal_type: "gold").yahoo_price_symbol
  end

  test "unpriced holdings are excluded from balance sheet and history" do
    unpriced = @family.accounts.create!(
      name: "Gold rounds",
      balance: 0,
      cash_balance: 0,
      currency: "USD",
      accountable: PhysicalMetal.new(metal_type: "gold", troy_ounces: 2, storage_label: "Home safe")
    )
    priced = @family.accounts.create!(
      name: "Silver bars",
      balance: 500,
      cash_balance: 0,
      currency: "USD",
      accountable: PhysicalMetal.new(
        metal_type: "silver", troy_ounces: 20, storage_label: "Vault box",
        manual_price_per_troy_ounce: 25, valuation_source: "Dealer quote", valuation_date: Date.current
      )
    )

    BalanceSheet::HistoricalAccountScope.new(@family).account_ids.tap do |ids|
      assert_not_includes ids, unpriced.id
      assert_includes ids, priced.id
    end
    assert_equal 500, BalanceSheet.new(@family).assets.total
  end

  test "cost basis is a total and per-ounce cost is derived from it" do
    metal = PhysicalMetal.new(metal_type: "silver", troy_ounces: 100, storage_label: "Safe", cost_basis: 4000)

    assert_equal 4000, metal.total_cost
    assert_equal 40, metal.cost_per_troy_ounce
  end

  test "no cost means no total, per-ounce cost or gain" do
    metal = PhysicalMetal.new(metal_type: "silver", troy_ounces: 100, storage_label: "Safe")

    assert_nil metal.total_cost
    assert_nil metal.cost_per_troy_ounce
    assert_nil metal.gain_loss_trend
  end

  test "an unpriced metal has no gain or loss instead of a false total loss" do
    account = @family.accounts.create!(name: "Silver", balance: 0, cash_balance: 0, currency: "USD",
                                       accountable: PhysicalMetal.new(metal_type: "silver", troy_ounces: 100, storage_label: "Safe", cost_basis: 4000))

    assert account.physical_metal.unpriced?
    assert_nil account.physical_metal.gain_loss_trend
  end

  test "a priced metal reports gain against what was paid" do
    account = @family.accounts.create!(name: "Silver", balance: 6000, cash_balance: 0, currency: "USD",
                                       accountable: PhysicalMetal.new(metal_type: "silver", troy_ounces: 100, storage_label: "Safe", cost_basis: 4000,
                                                                      manual_price_per_troy_ounce: 60, valuation_source: "Test", valuation_date: Date.current))

    trend = account.physical_metal.gain_loss_trend
    assert_equal 2000, trend.value.amount
    assert_in_delta 50.0, trend.percent, 0.001
  end
end
