# frozen_string_literal: true

require "test_helper"

module Options
  module Adversarial
  end
end

# Hostile Caveats tests from options-spec-v2 §1.5 Options::Caveats.for
class Options::Adversarial::CaveatsTest < ActiveSupport::TestCase
  DENYLIST = %w[TSLL TSLS NVDL NVDX TQQQ SQQQ SOXL SOXS UVXY GME SPCX AMC].freeze

  def caveats(underlying:, itm:, dte:)
    Options::Caveats.for(underlying: underlying, itm: itm, dte: dte)
  end

  test "denylist names including TSLL GME SPCX and leveraged ETFs emit :leveraged_or_hard_to_borrow" do
    DENYLIST.each do |sym|
      flags = caveats(underlying: sym, itm: false, dte: 30)
      assert_kind_of Array, flags
      assert_includes flags, :leveraged_or_hard_to_borrow, sym
      assert_includes flags, :borrow_dividends_not_modeled, "#{sym} must carry borrow/dividends caveat"
    end
  end

  test "ordinary names such as NVDA do not get leveraged or borrow caveats" do
    flags = caveats(underlying: "NVDA", itm: false, dte: 30)
    refute_includes flags, :leveraged_or_hard_to_borrow
    refute_includes flags, :borrow_dividends_not_modeled
    refute_includes flags, :early_assignment_not_modeled
  end

  test "ITM and dte <= 7 emits :early_assignment_not_modeled; dte 8 or OTM does not" do
    assert_includes caveats(underlying: "NVDA", itm: true, dte: 7), :early_assignment_not_modeled
    assert_includes caveats(underlying: "NVDA", itm: true, dte: 0), :early_assignment_not_modeled
    assert_includes caveats(underlying: "NVDA", itm: true, dte: 1), :early_assignment_not_modeled
    refute_includes caveats(underlying: "NVDA", itm: true, dte: 8), :early_assignment_not_modeled
    refute_includes caveats(underlying: "NVDA", itm: false, dte: 7), :early_assignment_not_modeled
    refute_includes caveats(underlying: "NVDA", itm: false, dte: 1), :early_assignment_not_modeled
  end

  test "denylist plus ITM short-dated stacks both caveat classes" do
    flags = caveats(underlying: "GME", itm: true, dte: 5)
    assert_includes flags, :leveraged_or_hard_to_borrow
    assert_includes flags, :early_assignment_not_modeled
    assert_includes flags, :borrow_dividends_not_modeled
  end

  test "SPCX and TSLL are flagged even with long DTE and OTM" do
    %w[SPCX TSLL].each do |sym|
      flags = caveats(underlying: sym, itm: false, dte: 45)
      assert_includes flags, :leveraged_or_hard_to_borrow
      refute_includes flags, :early_assignment_not_modeled
    end
  end
end
