class AddSourceToResearchWatchlistEntries < ActiveRecord::Migration[8.0]
  def change
    # Who put the entry on the list: the member themself or their AI assistant.
    # Existing rows are the member's own.
    add_column :research_watchlist_entries, :source, :string, null: false, default: "user"
    add_check_constraint :research_watchlist_entries, "source IN ('user', 'assistant')", name: "research_watchlist_entries_source"
    add_index :research_watchlist_entries, [ :user_id, :source, :created_at ], name: "index_research_watchlist_entries_on_user_source_created"
  end
end
