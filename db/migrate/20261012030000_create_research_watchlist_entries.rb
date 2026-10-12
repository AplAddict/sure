class CreateResearchWatchlistEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :research_watchlist_entries, id: :uuid do |t|
      t.references :user, null: false, foreign_key: true, type: :uuid
      t.references :security, null: false, foreign_key: true, type: :uuid
      t.string :status, null: false, default: "watching"
      t.integer :priority, null: false, default: 3
      t.text :thesis
      t.timestamps
    end

    add_index :research_watchlist_entries, [ :user_id, :security_id ], unique: true
    add_check_constraint :research_watchlist_entries, "status IN ('watching', 'researching', 'ready', 'archived')", name: "research_watchlist_entries_status"
    add_check_constraint :research_watchlist_entries, "priority BETWEEN 1 AND 5", name: "research_watchlist_entries_priority"
  end
end
