# Investment insights are derived from the accounts one person can see, and
# accounts are shared per user, not per family. A nullable owner lets those
# insights be private to the member they were computed for while every
# existing (family-wide) insight keeps user_id NULL and behaves as before.
class AddUserToInsights < ActiveRecord::Migration[8.1]
  def change
    add_reference :insights, :user, type: :uuid, null: true, index: false,
                  foreign_key: { on_delete: :cascade }
    add_index :insights, [ :user_id, :status ], name: "index_insights_on_user_id_and_status"
  end
end
