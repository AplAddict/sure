class CreateSecurityFundamentals < ActiveRecord::Migration[8.1]
  def change
    create_table :security_fundamentals, id: :uuid do |t|
      t.references :security, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :payload, null: false, default: {}
      t.string :source, null: false, default: "yahoo_finance"
      t.datetime :fetched_at
      t.datetime :last_attempt_at
      t.string :last_error
      t.timestamps
    end
  end
end
