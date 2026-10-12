require "test_helper"

class Insight::Generators::IdleCashGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @owner = users(:family_admin)
    @member = users(:family_member)
    @family.accounts.destroy_all
  end

  test "an idle account only its owner can access is never named in a family-wide insight" do
    create_idle_account("Private Savings", owner: @owner)

    assert_empty Insight::Generators::IdleCashGenerator.new(@family).generate
  end

  test "an idle account every active member can access produces a family-wide insight" do
    account = create_idle_account("Joint Savings", owner: @owner)
    account.share_with!(@member, permission: "read_only")

    insights = Insight::Generators::IdleCashGenerator.new(@family).generate

    assert_equal 1, insights.size
    assert_equal "Joint Savings", insights.first.facts[:account]
    assert_nil insights.first.user_id
  end

  test "revoking a member's access removes the insight on the next run" do
    account = create_idle_account("Was Joint", owner: @owner)
    account.share_with!(@member)
    assert_equal 1, Insight::Generators::IdleCashGenerator.new(@family).generate.size

    account.unshare_with!(@member)

    assert_empty Insight::Generators::IdleCashGenerator.new(@family).generate
  end

  private
    def create_idle_account(name, owner:)
      @family.accounts.create!(name: name, balance: 20_000, cash_balance: 20_000, currency: @family.currency, owner: owner,
                               status: "active", accountable: Depository.new)
    end
end
