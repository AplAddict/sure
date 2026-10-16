class CreateOptionQuotes < ActiveRecord::Migration[8.0]
  def change
    # Public market data for listed option contracts; deliberately no family or
    # user column. It is only ever joined to a user's own positions by symbol.
    create_table :option_quotes, id: :uuid do |t|
      t.string :contract_symbol, null: false
      t.string :underlying, null: false
      t.string :option_type, null: false
      t.decimal :strike, precision: 18, scale: 4, null: false
      t.date :expiration, null: false
      t.decimal :last_price, precision: 18, scale: 4
      t.decimal :bid, precision: 18, scale: 4
      t.decimal :ask, precision: 18, scale: 4
      t.decimal :change, precision: 18, scale: 4
      t.decimal :percent_change, precision: 18, scale: 6
      t.decimal :implied_volatility, precision: 12, scale: 6
      t.integer :open_interest
      t.integer :volume
      t.decimal :underlying_price, precision: 18, scale: 4
      t.datetime :last_trade_at
      # As-of of the quote itself (Yahoo's regularMarketTime), and the trading
      # date it belongs to. fetched_at below is bookkeeping, never the as-of.
      t.datetime :quote_time
      t.date :session_date
      # Last session's mark and its date, rolled forward by the refresher when a
      # new session_date arrives; the baseline for day gain.
      t.decimal :prev_session_mark, precision: 18, scale: 4
      t.date :prev_session_date
      t.decimal :underlying_prev_close, precision: 18, scale: 4
      # Yahoo's contractSize ("REGULAR", "MINI"). Lookups refuse anything else.
      t.string :contract_size, default: "REGULAR"
      t.datetime :fetched_at, null: false
      t.string :source, null: false, default: "yahoo_finance"
      t.string :currency, null: false, default: "USD"
      t.timestamps
    end

    add_index :option_quotes, :contract_symbol, unique: true
    add_index :option_quotes, :underlying
    add_index :option_quotes, :expiration
    add_index :option_quotes, [ :underlying, :expiration ]
    add_check_constraint :option_quotes, "option_type IN ('CALL', 'PUT')", name: "option_quotes_option_type"
    add_check_constraint :option_quotes, "strike > 0", name: "option_quotes_positive_strike"
    add_check_constraint :option_quotes, "contract_symbol !~ '^[[:space:]]*$'", name: "option_quotes_nonblank_contract_symbol"
    add_check_constraint :option_quotes, "underlying ~ '^[A-Z]{1,5}$'", name: "option_quotes_underlying_format"
    add_check_constraint :option_quotes, "(prev_session_mark IS NULL) = (prev_session_date IS NULL)", name: "option_quotes_prev_session_baseline"
    add_check_constraint :option_quotes, "(quote_time IS NULL) = (session_date IS NULL)", name: "option_quotes_quote_session"
  end
end
