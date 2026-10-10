class AddOwnershipShareToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :ownership_share, :decimal, precision: 7, scale: 6, default: "1.0", null: false
    add_check_constraint :accounts, "ownership_share > 0 AND ownership_share <= 1", name: "accounts_ownership_share_range"
  end
end
