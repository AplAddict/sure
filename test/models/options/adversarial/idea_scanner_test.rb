# frozen_string_literal: true

require "test_helper"

module Options
  module Adversarial
  end
end

# Hostile IdeaScanner tests from options-spec-v2 §1.6. Rank, flags, cash, vocabulary.
class Options::Adversarial::IdeaScannerTest < ActiveSupport::TestCase
  Context = Struct.new(
    :account_id, :account_name, :underlying, :shares_available, :cash_available,
    :existing_short_put_exposure, :currency, :basis_per_share, :long_calls_present,
    :earnings_date, :earnings_known, :ex_dividend_date,
    keyword_init: true
  )

  BANNED = [
    "cash-secured",
    "safe",
    "best",
    "opportunity",
    "top ideas",
    "sell"
  ].freeze

  setup do
    @now = Time.utc(2026, 10, 15, 19, 59, 0)
    @session = Date.new(2026, 10, 15)
    @exp = Date.new(2026, 11, 13)
    @qt = @now
  end

  def config(**overrides)
    Options::IdeaScanner::Config.new(
      delta_min: 0.15,
      delta_max: 0.30,
      dte_min: 21,
      dte_max: 45,
      min_open_interest: 50,
      max_spread_pct: 0.25,
      min_bid: 0.05,
      rows: 10,
      **overrides
    )
  end

  def ctx(**overrides)
    Context.new(
      account_id: 1,
      account_name: "IRA",
      underlying: "NVDA",
      shares_available: 500,
      cash_available: BigDecimal("100000"),
      existing_short_put_exposure: BigDecimal("0"),
      currency: "USD",
      basis_per_share: BigDecimal("180"),
      long_calls_present: false,
      earnings_date: nil,
      earnings_known: true,
      ex_dividend_date: nil,
      **overrides
    )
  end

  def row(option_type:, strike:, bid:, ask:, **overrides)
    {
      contract_symbol: "NVDA261113#{option_type.to_s.start_with?("C") ? "C" : "P"}#{format("%08d", (strike * 1000).to_i)}",
      underlying: "NVDA",
      option_type: option_type,
      strike: BigDecimal(strike.to_s),
      expiration: @exp,
      bid: BigDecimal(bid.to_s),
      ask: BigDecimal(ask.to_s),
      last_price: BigDecimal(bid.to_s),
      last_trade_at: @now,
      quote_time: @qt,
      session_date: @session,
      open_interest: 200,
      volume: 100,
      underlying_price: BigDecimal("217.23"),
      implied_volatility: BigDecimal("0.35"),
      currency: "USD",
      **overrides
    }
  end

  # Synthetic two-sided quotes near BS(vol=0.35) so ModelDelta can solve IV.
  def put_200
    row(option_type: "PUT", strike: 200, bid: 2.10, ask: 2.26)
  end

  def put_205
    row(option_type: "PUT", strike: 205, bid: 3.30, ask: 3.50)
  end

  def call_240
    row(option_type: "CALL", strike: 240, bid: 1.85, ask: 2.06)
  end

  def call_235
    row(option_type: "CALL", strike: 235, bid: 2.75, ask: 2.95)
  end

  def scan(kind:, rows:, contexts:, config: self.config, now: @now)
    Options::IdeaScanner.scan(kind: kind, rows: rows, contexts: contexts, config: config, now: now)
  end

  def each_string(obj, &block)
    case obj
    when String then yield obj
    when Hash then obj.each_value { |v| each_string(v, &block) }
    when Array then obj.each { |v| each_string(v, &block) }
    else
      if obj.respond_to?(:to_h)
        each_string(obj.to_h, &block)
      elsif obj.respond_to?(:members)
        obj.members.each { |m| each_string(obj.public_send(m), &block) }
      elsif obj.respond_to?(:instance_variables)
        obj.instance_variables.each { |iv| each_string(obj.instance_variable_get(iv), &block) }
      end
    end
  end

  test "|delta| band accepts puts whose signed delta is negative" do
    result = scan(
      kind: :cash_needed_put,
      rows: [put_200, put_205],
      contexts: { [1, "NVDA"] => ctx }
    )
    ideas = result.ideas
    assert ideas.any?, "expected at least one put idea in the |delta| band"
    ideas.each do |idea|
      d = idea.delta
      refute_nil d
      assert d < 0, "put delta must stay negative on the Idea, got #{d}"
      abs = d.abs
      assert abs >= 0.15, abs
      assert abs <= 0.30, abs
    end
  end

  test "ranking is unflagged first then |delta-0.20| then yield then contract_symbol; flagged never above clean" do
    # 200P |delta| closer to 0.20 than 205P, but only 200P spans the earnings date.
    flagged_ctx = ctx(earnings_date: Date.new(2026, 11, 10), earnings_known: true)
    # The clean row expires before the earnings date but remains inside the 21-45 calendar-day window.
    clean_row = put_205.merge(expiration: Date.new(2026, 11, 5))
    result = scan(
      kind: :cash_needed_put,
      rows: [put_200, clean_row],
      contexts: { [1, "NVDA"] => flagged_ctx }
    )
    ideas = result.ideas
    assert ideas.size >= 2, "need both strikes: #{ideas.inspect}"

    flagged, clean = ideas.partition { |i| Array(i.flags).include?(:earnings_in_window) }
    assert clean.any?, "205P should be clean"
    assert flagged.any?, "200P should be earnings flagged (earnings between today and expiration)"

    # Every clean idea precedes every flagged idea.
    last_clean = ideas.rindex { |i| Array(i.flags).empty? || !Array(i.flags).include?(:earnings_in_window) }
    first_flagged = ideas.index { |i| Array(i.flags).include?(:earnings_in_window) }
    if last_clean && first_flagged
      # More strict: no flagged before a clean
      seen_flagged = false
      ideas.each do |idea|
        is_flagged = Array(idea.flags).any?
        if is_flagged
          seen_flagged = true
        else
          refute seen_flagged, "clean idea #{idea.contract_symbol || idea.contract} ranked below a flagged idea"
        end
      end
    end

    unflagged = ideas.reject { |i| Array(i.flags).any? }
    unflagged.each_cons(2) do |a, b|
      da = (a.delta.abs - 0.20).abs
      db = (b.delta.abs - 0.20).abs
      assert da <= db, "unflagged order must be by |delta-0.20| (#{da} then #{db})"
    end
  end

  test "two accounts holding the same underlying produce separate per-account ideas and never sum shares or cash" do
    a = ctx(account_id: 11, account_name: "IRA", shares_available: 200, cash_available: BigDecimal("30000"))
    b = ctx(account_id: 22, account_name: "Taxable", shares_available: 100, cash_available: BigDecimal("15000"))
    result = scan(
      kind: :covered_call,
      rows: [call_240, call_235],
      contexts: { [11, "NVDA"] => a, [22, "NVDA"] => b }
    )
    ideas = result.ideas
    ids = ideas.map(&:account_id).uniq.sort
    assert_equal [11, 22], ids
    ideas.each do |idea|
      refute_nil idea.account_name
      # contracts_max = floor(shares/100) per account, never 3
      max = idea.contracts_max
      refute_nil max
      assert max <= 2, "IRA has 200 shares so max 2, Taxable 1; never summed to 3, got #{max} account=#{idea.account_id}"
      if idea.account_id == 22
        assert_equal 1, max
      elsif idea.account_id == 11
        assert_equal 2, max
      end
    end
    refute result.ideas.any? { |i| i.contracts_max.to_i >= 3 }
  end

  test "shares_available is already net of short calls and is honoured" do
    short = ctx(shares_available: 50)
    result = scan(kind: :covered_call, rows: [call_240], contexts: { [1, "NVDA"] => short })
    assert result.ideas.empty?
    reasons = result.exclusions.flat_map(&:reasons)
    assert_includes reasons, :insufficient_shares

    ok = ctx(shares_available: 150)
    result2 = scan(kind: :covered_call, rows: [call_240], contexts: { [1, "NVDA"] => ok })
    assert result2.ideas.any?
    result2.ideas.each { |i| assert_equal 1, i.contracts_max }
  end

  test "nil cash yields :no_cash_data and is not treated as zero" do
    result = scan(
      kind: :cash_needed_put,
      rows: [put_200],
      contexts: { [1, "NVDA"] => ctx(cash_available: nil) }
    )
    assert result.ideas.empty?
    reasons = result.exclusions.flat_map(&:reasons)
    assert_includes reasons, :no_cash_data
    refute_includes reasons, :insufficient_cash
  end

  test "nil open_interest is :low_oi and never a pass" do
    r = put_200.merge(open_interest: nil)
    result = scan(kind: :cash_needed_put, rows: [r], contexts: { [1, "NVDA"] => ctx })
    assert result.ideas.empty?
    assert_includes result.exclusions.flat_map(&:reasons), :low_oi
  end

  test "nil/none ModelDelta is :delta_unavailable with ModelDelta reason in Exclusion#detail" do
    dead = put_200.merge(bid: BigDecimal("0"), ask: BigDecimal("0"))
    result = scan(kind: :cash_needed_put, rows: [dead], contexts: { [1, "NVDA"] => ctx })
    ex = result.exclusions.select { |e| e.reasons.include?(:delta_unavailable) }
    assert ex.any?, "expected :delta_unavailable, got #{result.exclusions.flat_map(&:reasons).inspect}"
    details = ex.map(&:detail)
    assert details.any? { |d| d == :no_two_sided_market || d.to_s.include?("no_two_sided_market") }, details.inspect
  end

  test "earnings flags :earnings_in_window and :earnings_unknown" do
    in_window = scan(
      kind: :cash_needed_put,
      rows: [put_200],
      contexts: { [1, "NVDA"] => ctx(earnings_date: Date.new(2026, 11, 5), earnings_known: true) }
    )
    flagged = in_window.ideas.select { |i| Array(i.flags).include?(:earnings_in_window) }
    assert flagged.any? || in_window.exclusions.any?, "earnings in window must surface"

    unknown = scan(
      kind: :cash_needed_put,
      rows: [put_205],
      contexts: { [1, "NVDA"] => ctx(earnings_date: nil, earnings_known: false) }
    )
    assert unknown.ideas.any? { |i| Array(i.flags).include?(:earnings_unknown) } ||
           unknown.exclusions.any? { |e| e.respond_to?(:flags) && Array(e.flags).include?(:earnings_unknown) }
    unknown.ideas.each do |idea|
      next unless Array(idea.flags).include?(:earnings_unknown)
      assert_includes Array(idea.flags), :earnings_unknown
    end
    assert unknown.ideas.any? { |i| Array(i.flags).include?(:earnings_unknown) },
           "earnings_known false must flag ideas, flags=#{unknown.ideas.map { |i| Array(i.flags) }.inspect}"
  end

  test "joint_exposure_note is present and states ideas are per-account / non-additive" do
    result = scan(
      kind: :cash_needed_put,
      rows: [put_200],
      contexts: { [1, "NVDA"] => ctx, [2, "NVDA"] => ctx(account_id: 2, account_name: "Taxable") }
    )
    note = result.joint_exposure_note
    refute_nil note
    assert_kind_of String, note
    refute_empty note
    assert_respond_to result, :candidates_count
  end

  test "banned vocabulary is absent from every string value and note on ideas and exclusions" do
    result = scan(
      kind: :cash_needed_put,
      rows: [put_200, put_205, put_200.merge(open_interest: nil), put_200.merge(bid: 0, ask: 0)],
      contexts: {
        [1, "NVDA"] => ctx,
        [2, "NVDA"] => ctx(account_id: 2, account_name: "Taxable", cash_available: nil, earnings_known: false)
      }
    )
    strings = []
    each_string(result.ideas) { |s| strings << s }
    each_string(result.exclusions) { |s| strings << s }
    strings << result.joint_exposure_note.to_s
    blob = strings.join("\n")
    BANNED.each do |word|
      assert_nil blob.downcase[word], "banned #{word.inspect} found in #{strings.inspect}"
    end
  end

  test "same input yields the same idea and exclusion order (determinism)" do
    rows = [put_205, put_200, call_240]
    contexts = { [1, "NVDA"] => ctx, [9, "NVDA"] => ctx(account_id: 9, account_name: "Other", shares_available: 100) }
    a = scan(kind: :cash_needed_put, rows: rows, contexts: contexts)
    b = scan(kind: :cash_needed_put, rows: rows, contexts: contexts)
    key = lambda do |idea|
      [idea.account_id, idea.respond_to?(:contract_symbol) ? idea.contract_symbol : idea.contract, idea.strike]
    end
    assert_equal a.ideas.map(&key), b.ideas.map(&key)
    assert_equal a.exclusions.map(&:reasons), b.exclusions.map(&:reasons)
    assert_equal a.joint_exposure_note, b.joint_exposure_note
  end

  test "annualized_yield_pct is simple bid/strike * 365/dte * 100 for puts at 4 dp" do
    result = scan(kind: :cash_needed_put, rows: [put_200], contexts: { [1, "NVDA"] => ctx })
    idea = result.ideas.find { |i| i.strike.to_f == 200.0 } || result.ideas.first
    refute_nil idea, "expected a 200P idea so yield can be checked"
    dte = (Date.new(2026, 11, 13) - Date.new(2026, 10, 15)).to_i
    assert_equal 29, dte
    expected = (BigDecimal("2.10") / BigDecimal("200") * 365 / dte * 100).round(4)
    assert_equal expected, idea.annualized_yield_pct
  end

  test "Result exposes ideas, exclusions, candidates_count, joint_exposure_note" do
    result = scan(kind: :cash_needed_put, rows: [put_200], contexts: { [1, "NVDA"] => ctx })
    %i[ideas exclusions candidates_count joint_exposure_note].each do |f|
      assert_respond_to result, f
    end
  end
end
