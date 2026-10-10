class CreateSecurityHeadlineAnalyses < ActiveRecord::Migration[8.0]
  def change
    create_table :security_headline_analyses, id: :uuid do |t|
      t.references :security, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      t.string :source_digest, null: false
      t.datetime :source_generated_at
      t.datetime :analyzed_at
      t.string :status, null: false, default: "unavailable"
      t.string :provider_model
      t.jsonb :payload, null: false, default: {}
      t.string :last_error
      t.timestamps
    end
  end
end
