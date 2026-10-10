class AddYahooAutoPricingToPhysicalMetals < ActiveRecord::Migration[8.1]
  def change
    add_column :physical_metals, :auto_price_enabled, :boolean, null: false, default: false
    add_column :physical_metals, :price_symbol, :string
    add_check_constraint :physical_metals,
                         "price_symbol IS NULL OR price_symbol IN ('GC=F', 'SI=F')",
                         name: "physical_metals_price_symbol"
  end
end
