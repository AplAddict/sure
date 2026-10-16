require "test_helper"

class OptionsDeskHelperTest < ActionView::TestCase
  include InvestmentsHelper

  Exclusion = Struct.new(:account_id, :account_name, :underlying, :reasons, keyword_init: true)

  def exclusion(account_id, name, reasons, underlying: "NVDA")
    Exclusion.new(account_id: account_id, account_name: name, underlying: underlying, reasons: reasons)
  end

  test "exclusion summary returns account name, reason set and contract count per account" do
    entries = Array.new(385) { |i| exclusion("a1", "Alpha", %i[insufficient_shares], underlying: "T#{i}") } +
              [ exclusion("a1", "Alpha", %i[low_oi insufficient_shares]), exclusion("a2", "Beta", %i[insufficient_shares]) ]

    summary = options_desk_exclusion_summary(entries)

    assert_equal [ [ "Alpha", [ :insufficient_shares ], 385 ], [ "Alpha", [ :insufficient_shares, :low_oi ], 1 ], [ "Beta", [ :insufficient_shares ], 1 ] ], summary
  end

  test "the same reasons in a different order form one reason set" do
    summary = options_desk_exclusion_summary([ exclusion("a1", "Alpha", %i[low_oi no_bid]), exclusion("a1", "Alpha", %i[no_bid low_oi]) ])

    assert_equal [ [ "Alpha", [ :low_oi, :no_bid ], 2 ] ], summary
  end

  test "accounts never pool even when names and reasons match" do
    summary = options_desk_exclusion_summary([ exclusion("a1", "Same", %i[no_cash_data]), exclusion("a2", "Same", %i[no_cash_data]) ])

    assert_equal [ [ "Same", [ :no_cash_data ], 1 ], [ "Same", [ :no_cash_data ], 1 ] ], summary
  end

  test "the per-account cap hides the smallest reason sets and reports how many" do
    entries = (1..4).flat_map { |reason| Array.new(reason) { exclusion("a1", "Alpha", [ :"r#{reason}" ]) } } + [ exclusion("a2", "Beta", %i[x]) ]

    rows, hidden = options_desk_exclusion_rows(entries, limit: 2)

    assert_equal [ [ "a1", 4 ], [ "a1", 3 ], [ "a2", 1 ] ], rows.map { |row| [ row.account_id, row.count ] }
    assert_equal [ [ "Alpha", 2 ] ], hidden
  end

  test "delta reason labels cover the known reasons and fall back to Unavailable" do
    {
      too_close_to_expiry: "Too close to expiry",
      no_two_sided_market: "No two-sided market",
      no_direct_quote: "No direct quote",
      wide_spread: "Unavailable",
      iv_unsolved: "Unavailable",
      nil => "Unavailable",
      "<b>x</b>" => "Unavailable"
    }.each do |reason, label|
      assert_equal label, options_desk_delta_reason(reason), reason.inspect
    end
  end

  test "delta cell renders a dash and a short reason, never a fabricated value" do
    model = Options::ModelDelta::Result.new(value: nil, iv: nil, reason: :too_close_to_expiry)
    row = OptionsDesk::Row.members.index_with { nil }.merge(model_delta: model, position_delta: nil)

    html = options_desk_delta_cell(OptionsDesk::Row.new(**row))

    assert_equal "— Too close to expiry", Nokogiri::HTML.fragment(html).text.squish
    assert_not_includes html, "tabular-nums"
  end

  test "a nil model delta result is Unavailable" do
    row = OptionsDesk::Row.new(**OptionsDesk::Row.members.index_with { nil })

    assert_equal "— Unavailable", Nokogiri::HTML.fragment(options_desk_delta_cell(row)).text.squish
  end

  test "contract label needs underlying, strike and type or falls back to nil" do
    base = OptionsDesk::Row.members.index_with { nil }.merge(underlying: "NVDA", option_type: "PUT", strike: BigDecimal("215"), currency: "USD")

    assert_equal "NVDA $215 Put", options_desk_contract_label(OptionsDesk::Row.new(**base))
    assert_equal "NVDA $215.5 Call", options_desk_contract_label(OptionsDesk::Row.new(**base.merge(option_type: "CALL", strike: BigDecimal("215.5"))))
    assert_equal "NVDA 215 Put", options_desk_contract_label(OptionsDesk::Row.new(**base.merge(currency: "ZZZ")))
    assert_nil options_desk_contract_label(OptionsDesk::Row.new(**base.merge(strike: nil)))
    assert_nil options_desk_contract_label(OptionsDesk::Row.new(**base.merge(underlying: nil)))
    assert_nil options_desk_contract_label(OptionsDesk::Row.new(**base.merge(option_type: "WEIRD")))
  end
end
