require "test_helper"

class AccountOwnershipShareTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = @family.accounts.create!(name: "Shared Club", balance: 10_000, currency: "USD", accountable: Investment.new)
  end

  test "defaults to full ownership" do
    assert_equal 1, @account.ownership_share
    assert_equal "100", @account.ownership_percentage
  end

  test "percentage setter stores a fractional share" do
    @account.update!(ownership_percentage: "20")
    assert_equal BigDecimal("0.2"), @account.reload.ownership_share
    assert_equal "20", @account.ownership_percentage
  end

  test "rejects zero and over one hundred percent" do
    @account.ownership_percentage = "0"
    assert_not @account.valid?
    @account.ownership_percentage = "101"
    assert_not @account.valid?
  end

  test "balance sheet counts only the owned share" do
    full = BalanceSheet.new(@family).assets.total
    @account.update!(ownership_percentage: "20")
    shared = BalanceSheet.new(@family).assets.total
    assert_in_delta 8_000, full.to_d - shared.to_d, 0.01
  end
end
