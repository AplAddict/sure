require "test_helper"

class OptionQuoteConstraintTest < ActiveSupport::TestCase
  def attrs(overrides = {})
    {
      contract_symbol: "NVDA261113P00215000",
      underlying: "NVDA",
      option_type: "PUT",
      strike: BigDecimal("215"),
      expiration: Date.new(2026, 11, 13),
      fetched_at: Time.utc(2026, 10, 15, 15, 0),
      quote_time: Time.utc(2026, 10, 15, 14, 55),
      session_date: Date.new(2026, 10, 15),
      source: "yahoo_finance",
      currency: "USD"
    }.merge(overrides)
  end

  test "database constraints reject invalid option quote invariants without model validations" do
    invalid_rows = [
      { option_type: "OTHER" },
      { strike: 0 },
      { contract_symbol: " \t " },
      { underlying: "NVDA1" },
      { prev_session_mark: BigDecimal("1.25"), prev_session_date: nil },
      { quote_time: nil }
    ]

    invalid_rows.each_with_index do |overrides, index|
      assert_raises(ActiveRecord::StatementInvalid, "invalid row #{index} should violate a database check") do
        row_attrs = attrs(overrides)
        row_attrs[:contract_symbol] = "NVDA261113P#{format('%08d', 215_000 + index)}" unless overrides.key?(:contract_symbol)

        OptionQuote.transaction(requires_new: true) do
          OptionQuote.insert_all!([ row_attrs ])
        end
      end
    end
  end

  test "database accepts a valid current quote with an unknown contract size" do
    OptionQuote.insert_all!([ attrs(contract_size: nil) ])

    quote = OptionQuote.find_by!(contract_symbol: "NVDA261113P00215000")
    assert_equal "PUT", quote.option_type
    assert_equal BigDecimal("215"), quote.strike
    assert_equal Date.new(2026, 10, 15), quote.session_date
    assert_nil quote.contract_size
  end
end
