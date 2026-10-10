class AddRawOptionsPayloadToSnaptradeAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :snaptrade_accounts, :raw_options_payload, :jsonb, default: [], null: false
  end
end