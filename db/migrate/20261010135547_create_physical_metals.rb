class CreatePhysicalMetals < ActiveRecord::Migration[8.1]
  def change
    create_table :physical_metals do |t|
      t.string :metal_type, null: false
      t.decimal :troy_ounces, precision: 18, scale: 6, null: false
      t.string :storage_label, null: false
      t.jsonb :locked_attributes, null: false, default: {}
      t.decimal :cost_basis, precision: 19, scale: 4
      t.string :valuation_state, null: false, default: "unpriced"
      t.decimal :manual_price_per_troy_ounce, precision: 19, scale: 4
      t.string :valuation_source
      t.date :valuation_date
      t.timestamps
    end

    add_check_constraint :physical_metals, "metal_type IN ('gold', 'silver')", name: "physical_metals_metal_type"
    add_check_constraint :physical_metals, "troy_ounces > 0", name: "physical_metals_positive_troy_ounces"
    add_check_constraint :physical_metals, "cost_basis IS NULL OR cost_basis >= 0", name: "physical_metals_nonnegative_cost_basis"
    add_check_constraint :physical_metals, "valuation_state IN ('unpriced', 'manually_valued')", name: "physical_metals_valuation_state"
    add_check_constraint :physical_metals, <<~SQL.squish, name: "physical_metals_complete_manual_valuation"
      (valuation_state = 'unpriced' AND manual_price_per_troy_ounce IS NULL AND valuation_source IS NULL AND valuation_date IS NULL)
      OR
      (valuation_state = 'manually_valued' AND manual_price_per_troy_ounce > 0 AND valuation_source IS NOT NULL AND valuation_date IS NOT NULL)
    SQL
  end
end
