require "test_helper"

class PhysicalMetalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "creates an unpriced physical metal account without a valuation entry" do
    assert_difference [ "Account.count", "PhysicalMetal.count" ], 1 do
      assert_no_difference "Entry.count" do
        post physical_metals_path, params: {
          account: {
            name: "Gold rounds",
            currency: "USD",
            accountable_type: "PhysicalMetal",
            accountable_attributes: {
              metal_type: "gold", troy_ounces: "2.5", storage_label: "Home safe"
            }
          }
        }
      end
    end

    account = Account.order(:created_at).last
    assert_redirected_to account_path(account)
    assert_equal 0, account.balance
    assert account.physical_metal.unpriced?
  end

  test "creates a dated reconciliation for a manual valuation" do
    post physical_metals_path, params: {
      account: {
        name: "Silver bars",
        currency: "USD",
        accountable_type: "PhysicalMetal",
        accountable_attributes: {
          metal_type: "silver", troy_ounces: "20", storage_label: "Vault box",
          manual_price_per_troy_ounce: "25", valuation_source: "Dealer quote", valuation_date: Date.current.to_s
        }
      }
    }

    account = Account.order(:created_at).last
    assert_redirected_to account_path(account)
    assert_equal 500, account.balance
    entry = account.entries.valuations.find_by!(date: Date.current)
    assert_equal "reconciliation", entry.entryable.kind
    assert_equal 500, entry.amount
  end

  test "returns validation errors for an invalid manual valuation" do
    assert_no_difference "Account.count" do
      post physical_metals_path, params: {
        account: {
          name: "Gold rounds", currency: "USD", accountable_type: "PhysicalMetal",
          accountable_attributes: { metal_type: "gold", troy_ounces: "1", storage_label: "Home safe", manual_price_per_troy_ounce: "0" }
        }
      }
    end

    assert_response :unprocessable_entity
    assert_match "must be greater than 0", response.body
  end

  test "does not allow a read-only share to update a physical metal account" do
    owner = users(:family_admin)
    reader = users(:family_member)
    account = owner.family.accounts.create!(
      name: "Gold rounds", owner: owner, balance: 0, cash_balance: 0, currency: "USD",
      accountable: PhysicalMetal.new(metal_type: "gold", troy_ounces: 1, storage_label: "Home safe")
    )
    account.share_with!(reader, permission: "read_only")
    sign_in reader

    patch physical_metal_path(account), params: { account: { name: "Changed" } }

    assert_redirected_to account_path(account)
    assert_equal "Gold rounds", account.reload.name
  end
end
