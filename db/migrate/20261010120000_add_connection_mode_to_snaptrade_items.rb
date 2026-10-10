class AddConnectionModeToSnaptradeItems < ActiveRecord::Migration[8.1]
  def change
    add_column :snaptrade_items, :connection_mode, :string, null: false, default: "oauth"
    add_check_constraint :snaptrade_items,
                         "connection_mode IN ('oauth', 'personal_profile')",
                         name: "snaptrade_items_connection_mode"
  end
end
