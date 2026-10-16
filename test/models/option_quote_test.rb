require "test_helper"

class OptionQuoteTest < ActiveSupport::TestCase
  def build(overrides = {})
    OptionQuote.new({
      contract_symbol: "NVDA261113P00215000", underlying: "NVDA", option_type: "PUT",
      strike: 215, expiration: Date.new(2026, 11, 13), fetched_at: Time.current
    }.merge(overrides))
  end

  test "normalize_symbol strips internal spaces and upcases" do
    assert_equal "NVDA261113P00215000", OptionQuote.normalize_symbol("NVDA  261113P00215000")
    assert_equal "NVDA261113P00215000", OptionQuote.normalize_symbol(" nvda261113p00215000 ")
    assert_nil OptionQuote.normalize_symbol(nil)
  end

  test "stores the normalized symbol and is valid with only the required fields" do
    quote = build(contract_symbol: "NVDA  261113P00215000")

    assert quote.valid?, quote.errors.full_messages.to_sentence
    assert_equal "NVDA261113P00215000", quote.contract_symbol
  end

  test "contract_symbol is unique even when the duplicate has spaces" do
    build.save!

    duplicate = build(contract_symbol: "NVDA  261113P00215000")
    assert_not duplicate.valid?
    assert duplicate.errors.of_kind?(:contract_symbol, :taken)
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "rejects an unknown option type, a missing expiry/fetch time and a non-positive strike" do
    assert_not build(option_type: "STRADDLE").valid?
    assert_not build(expiration: nil).valid?
    assert_not build(fetched_at: nil).valid?
    assert_not build(strike: 0).valid?
    assert build(option_type: "CALL").valid?
  end

  test "missing numbers stay nil rather than zero" do
    quote = build.tap(&:save!).reload

    %i[last_price bid ask change percent_change implied_volatility open_interest volume underlying_price last_trade_at].each do |field|
      assert_nil quote.public_send(field), field
    end
    assert_equal "yahoo_finance", quote.source
    assert_equal "USD", quote.currency
  end

  test "for_contracts finds quotes by symbols given with or without spaces" do
    wanted = build.tap(&:save!)
    build(contract_symbol: "AAPL261113C00200000", underlying: "AAPL", option_type: "CALL").save!

    assert_equal [ wanted ], OptionQuote.for_contracts([ "NVDA  261113P00215000" ]).to_a
    assert_empty OptionQuote.for_contracts([])
  end

  test "fresh only returns quotes fetched inside the window" do
    new_quote = build(fetched_at: 2.hours.ago).tap(&:save!)
    build(contract_symbol: "NVDA261113P00220000", strike: 220, fetched_at: 40.hours.ago).save!

    assert_equal [ new_quote ], OptionQuote.fresh.to_a
    assert_equal 2, OptionQuote.fresh(48.hours).count
  end

  test "the table is global public data with no family or user column" do
    assert_empty OptionQuote.column_names & %w[family_id user_id account_id]
  end

  # --- v2 columns ------------------------------------------------------------

  test "carries the session bookkeeping columns, all unknown until fetched" do
    columns = OptionQuote.columns_hash

    assert_equal :datetime, columns["quote_time"].type
    assert_equal :date, columns["session_date"].type
    assert_equal :date, columns["prev_session_date"].type
    assert_equal [ 18, 4 ], [ columns["prev_session_mark"].precision, columns["prev_session_mark"].scale ]
    assert_equal [ 18, 4 ], [ columns["underlying_prev_close"].precision, columns["underlying_prev_close"].scale ]
    assert_equal "REGULAR", columns["contract_size"].default

    quote = build.tap(&:save!).reload
    %i[quote_time session_date prev_session_mark prev_session_date underlying_prev_close].each { |field| assert_nil quote.public_send(field), field }
    assert_equal "REGULAR", quote.contract_size
  end

  test "has a composite index on underlying and expiration" do
    indexes = ActiveRecord::Base.connection.indexes(:option_quotes).map(&:columns)

    assert_includes indexes, %w[underlying expiration]
  end

  # --- parse_occ ---------------------------------------------------------------

  test "parse_occ reads the padded, unpadded and digit-root OCC forms" do
    padded = OptionQuote.parse_occ("NVDA  261113P00215000")
    assert_equal({ root: "NVDA", expiration: Date.new(2026, 11, 13), option_type: "PUT", strike: BigDecimal("215") }, padded)
    assert_kind_of BigDecimal, padded[:strike]

    assert_equal padded, OptionQuote.parse_occ("NVDA261113P00215000")
    assert_equal padded, OptionQuote.parse_occ(" nvda261113p00215000 ")

    gme = OptionQuote.parse_occ("GME1  261113C00031000")
    assert_equal "GME1", gme[:root]
    assert_equal "CALL", gme[:option_type]
    assert_equal BigDecimal("31"), gme[:strike]
    assert_equal "GME1", OptionQuote.parse_occ("GME1261113C00031000")[:root]
  end

  test "parse_occ keeps fractional strikes exact" do
    assert_equal BigDecimal("2.5"), OptionQuote.parse_occ("F     261113C00002500")[:strike]
    assert_equal BigDecimal("1052.125"), OptionQuote.parse_occ("SPX   261113C01052125")[:strike]
  end

  test "parse_occ returns nil for anything that is not a complete OCC symbol" do
    [ nil, "", "   ", "NVDA", "261113P00215000", "NVDA  261113X00215000", "NVDA  261113P0021500", "NVDA  261113P002150000",
      "NVDA  261313P00215000", "NVDA  261132P00215000", "NVDA  261113P0021500A", 12345, "NV-A  261113P00215000" ].each do |bad|
      assert_nil OptionQuote.parse_occ(bad), bad.inspect
    end
  end

  test "parse_occ does not depend on the host time zone" do
    previous = ENV["TZ"]
    ENV["TZ"] = "America/Chicago"

    assert_equal Date.new(2026, 11, 13), OptionQuote.parse_occ("NVDA  261113P00215000")[:expiration]
  ensure
    ENV["TZ"] = previous
  end

  # --- lookup ------------------------------------------------------------------

  def lookup_args(overrides = {})
    { underlying: "NVDA", expiration: Date.new(2026, 11, 13), option_type: "PUT", strike: BigDecimal("215"), multiplier: 100 }.merge(overrides)
  end

  test "lookup joins on the structured fields, not the symbol text" do
    quote = build(contract_symbol: "NVDA261113P00215000").tap(&:save!)
    build(contract_symbol: "NVDA261113C00215000", option_type: "CALL").save!
    build(contract_symbol: "NVDA261120P00215000", expiration: Date.new(2026, 11, 20)).save!
    build(contract_symbol: "NVDA261113P00220000", strike: 220).save!

    assert_equal quote, OptionQuote.lookup(**lookup_args)
    assert_equal quote, OptionQuote.lookup(**lookup_args(option_type: "put", strike: "215.0", multiplier: BigDecimal("100")))
    assert_equal quote, OptionQuote.lookup(**lookup_args(strike: 215))
    assert_nil OptionQuote.lookup(**lookup_args(underlying: "AAPL"))
    assert_nil OptionQuote.lookup(**lookup_args(strike: 215.5))
  end

  test "lookup refuses non-standard deliverables: multiplier other than 100 or a non-REGULAR contract size" do
    build.save!

    assert_nil OptionQuote.lookup(**lookup_args(multiplier: 10))
    assert_nil OptionQuote.lookup(**lookup_args(multiplier: nil))
    assert_nil OptionQuote.lookup(**lookup_args(multiplier: 0))

    OptionQuote.update_all(contract_size: "MINI")
    assert_nil OptionQuote.lookup(**lookup_args)

    OptionQuote.update_all(contract_size: nil)
    assert_nil OptionQuote.lookup(**lookup_args), "an unknown contract size is not assumed to be regular"
  end

  test "lookup tolerates a nil strike or expiration by returning nil" do
    build.save!

    assert_nil OptionQuote.lookup(**lookup_args(strike: nil))
    assert_nil OptionQuote.lookup(**lookup_args(expiration: nil))
    assert_nil OptionQuote.lookup(**lookup_args(option_type: nil))
  end
end
