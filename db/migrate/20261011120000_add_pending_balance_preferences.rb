class AddPendingBalancePreferences < ActiveRecord::Migration[8.0]
  def up
    add_column :families, :include_pending_transactions_in_balances, :boolean, default: false, null: false unless column_exists?(:families, :include_pending_transactions_in_balances)
    add_column :accounts, :include_pending_in_balance, :boolean, default: false, null: false unless column_exists?(:accounts, :include_pending_in_balance)
  end

  def down
    remove_column :accounts, :include_pending_in_balance if column_exists?(:accounts, :include_pending_in_balance)
    remove_column :families, :include_pending_transactions_in_balances if column_exists?(:families, :include_pending_transactions_in_balances)
  end
end
