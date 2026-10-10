class CreateSecurityResearchSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :security_research_snapshots, id: :uuid do |t|
      t.references :security, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :payload, null: false, default: {}
      t.datetime :generated_at
      t.datetime :imported_at
      t.string :status, null: false, default: "unavailable"
      t.string :last_error
      t.timestamps
    end
  end
end
