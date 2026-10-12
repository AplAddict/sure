require "test_helper"

class AccountableTest < ActiveSupport::TestCase
  test "balance money is unavailable when a foreign account has no exchange rate" do
    family = families(:dylan_family)
    family.accounts.create!(
      name: "Foreign checking",
      balance: 100,
      currency: "EUR",
      accountable: Depository.new
    )
    ExchangeRate.stubs(:rates_for).returns({})

    assert_nil Depository.balance_money(family)
  end

  test "balance money converts every account when all rates exist" do
    family = families(:dylan_family)
    family.accounts.create!(
      name: "Foreign checking",
      balance: 100,
      currency: "EUR",
      accountable: Depository.new
    )
    expected_local_total = family.accounts.active.where(accountable_type: "Depository", currency: family.currency).sum(:balance)
    ExchangeRate.stubs(:rates_for).returns("EUR" => BigDecimal("1.5"))

    assert_equal expected_local_total + BigDecimal("150"), Depository.balance_money(family)
  end
end
