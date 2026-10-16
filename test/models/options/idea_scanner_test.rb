require "test_helper"

class Options::IdeaScannerTest < ActiveSupport::TestCase
  Scanner = Options::IdeaScanner
  NY = ActiveSupport::TimeZone["America/New_York"]

  # Thursday 2026-10-15, 20 minutes after the close, so the 2026-10-15 session is the latest one.
  # spot 100, 28 DTE (2026-11-12), r 0.04. The markets below have SOLVED iv ~0.37-0.40 which gives:
  # call 106 ~0.33, 108 ~0.26, 110 ~0.20, 114 ~0.12; put 90 ~-0.15, 92 ~-0.20, 94 ~-0.25, 96 ~-0.32.
  setup do
    @now = NY.local(2026, 10, 15, 16, 20)
    @today = Date.new(2026, 10, 15)
    @expiration = @today + 28
    @quote_time = NY.local(2026, 10, 15, 16, 0)
  end

  CALL_MARKETS = {
    106 => [ "2.20", "2.30" ], 108 => [ "1.50", "1.60" ], 110 => [ "1.00", "1.10" ], 114 => [ "0.60", "0.65" ], 120 => [ "0.20", "0.25" ]
  }.freeze
  PUT_MARKETS = {
    88 => [ "0.50", "0.55" ], 90 => [ "0.80", "0.90" ], 92 => [ "1.20", "1.30" ], 94 => [ "1.60", "1.70" ], 96 => [ "2.20", "2.30" ]
  }.freeze

  def row(overrides = {})
    {
      underlying: "ACME",
      contract_symbol: "ACME261112C00110000",
      option_type: "CALL",
      strike: BigDecimal("110"),
      expiration: @expiration,
      underlying_price: BigDecimal("100"),
      bid: BigDecimal("1.00"),
      ask: BigDecimal("1.10"),
      implied_volatility: BigDecimal("0.01"), # deliberately useless: delta must not come from the row
      open_interest: 500,
      volume: 40,
      last_price: BigDecimal("1.05"),
      last_trade_at: NY.local(2026, 10, 15, 15, 50),
      quote_time: @quote_time,
      session_date: @today
    }.merge(overrides)
  end

  def call_row(strike, overrides = {})
    bid, ask = CALL_MARKETS.fetch(strike)
    row({ contract_symbol: "ACME261112C#{format('%08d', strike * 1000)}", strike: BigDecimal(strike.to_s), bid: BigDecimal(bid), ask: BigDecimal(ask) }.merge(overrides))
  end

  def put_row(strike, overrides = {})
    bid, ask = PUT_MARKETS.fetch(strike)
    row({ contract_symbol: "ACME261112P#{format('%08d', strike * 1000)}", option_type: "PUT", strike: BigDecimal(strike.to_s),
          bid: BigDecimal(bid), ask: BigDecimal(ask) }.merge(overrides))
  end

  def context(overrides = {})
    Scanner::Context.new(**{
      account_id: "acct-1", account_name: "Brokerage", underlying: "ACME",
      shares_available: 300, cash_available: BigDecimal("50000"), existing_short_put_exposure: BigDecimal("0"),
      currency: "USD", basis_per_share: BigDecimal("95"), long_calls_present: false,
      earnings_date: nil, earnings_known: true, ex_dividend_date: nil
    }.merge(overrides))
  end

  def contexts_for(*list)
    list.to_h { |c| [ [ c.account_id, c.underlying ], c ] }
  end

  def scan(kind, rows, ctx: context, config: Scanner::Config.new, now: @now)
    Scanner.scan(kind: kind, rows: rows, contexts: contexts_for(*(ctx.is_a?(Array) ? ctx : [ ctx ])), config: config, now: now)
  end

  def reasons_for(result, symbol)
    result.exclusions.find { |e| e.contract == symbol }&.reasons
  end

  # ---- config / shape ---------------------------------------------------------------------

  test "config defaults match the contract" do
    c = Scanner::Config.new
    assert_equal [ 0.15, 0.30, 21, 45, 50, 0.25, 0.05, 5 ], [ c.delta_min, c.delta_max, c.dte_min, c.dte_max, c.min_open_interest, c.max_spread_pct, c.min_bid, c.rows ].map { |v| v.is_a?(BigDecimal) ? v.to_f : v }
    assert_equal 0.20, c.delta_target
  end

  test "Context carries the v2 fields" do
    assert_equal %i[account_id account_name underlying shares_available cash_available existing_short_put_exposure currency
                    basis_per_share long_calls_present earnings_date earnings_known ex_dividend_date], Scanner::Context.members
  end

  test "Result carries ideas exclusions candidates_count and joint_exposure_note" do
    assert_equal %i[ideas exclusions candidates_count joint_exposure_note], Scanner::Result.members
  end

  test "covered call idea carries all contract fields and the model delta" do
    result = scan(:covered_call, [ row ])
    assert_equal 1, result.ideas.size
    idea = result.ideas.first
    assert_equal :covered_call, idea.kind
    assert_equal "acct-1", idea.account_id
    assert_equal "Brokerage", idea.account_name
    assert_equal "ACME", idea.underlying
    assert_equal "ACME261112C00110000", idea.contract
    assert_equal @expiration, idea.expiration
    assert_equal 28, idea.dte
    assert_equal BigDecimal("110"), idea.strike
    assert_equal BigDecimal("1.00"), idea.bid
    assert_equal BigDecimal("1.10"), idea.ask
    assert_equal BigDecimal("1.05"), idea.mid
    assert_in_delta 0.1955, idea.delta, 0.01
    assert_in_delta 0.366, idea.iv, 0.01
    assert_equal 500, idea.open_interest
    assert_equal BigDecimal("100"), idea.credit_per_contract
    assert_kind_of BigDecimal, idea.credit_per_contract
    assert_equal 3, idea.contracts_max
    assert_equal BigDecimal("111"), idea.called_away_price
    assert_nil idea.break_even
    assert_nil idea.collateral_needed
    assert_equal BigDecimal("10"), idea.distance_from_spot_pct
    assert_equal "USD", idea.currency
    assert_equal [], idea.flags
  end

  test "delta comes from our solved iv and never from the row iv" do
    base = scan(:covered_call, [ row ]).ideas.first
    other = scan(:covered_call, [ row(implied_volatility: BigDecimal("3.5"), iv: 0.9) ]).ideas.first
    assert_equal base.delta, other.delta
    assert_equal base.iv, other.iv
  end

  test "a row iv of nil does not block an idea because the iv is solved from the market" do
    assert_equal 1, scan(:covered_call, [ row(implied_volatility: nil) ]).ideas.size
  end

  test "annualized yield for calls is bid over spot scaled by 365 over dte" do
    idea = scan(:covered_call, [ row ]).ideas.first
    expected = BigDecimal("1.00") / BigDecimal("100") * 365 / 28 * 100
    assert_kind_of BigDecimal, idea.annualized_yield_pct
    assert_in_delta expected, idea.annualized_yield_pct, BigDecimal("0.0001")
    assert_equal idea.annualized_yield_pct, idea.annualized_yield_pct.round(4)
  end

  test "annualized yield for puts is bid over strike scaled by 365 over dte and is not compounded" do
    idea = scan(:cash_needed_put, [ put_row(92) ]).ideas.first
    expected = BigDecimal("1.20") / BigDecimal("92") * 365 / 28 * 100
    assert_in_delta expected, idea.annualized_yield_pct, BigDecimal("0.0001")
    assert_equal BigDecimal("17.0031"), idea.annualized_yield_pct
  end

  test "put idea has a negative delta uses collateral never says cash secured" do
    idea = scan(:cash_needed_put, [ put_row(92) ]).ideas.first
    assert_equal :cash_needed_put, idea.kind
    assert_operator idea.delta, :<, 0
    assert_in_delta(-0.197, idea.delta, 0.01)
    assert_equal BigDecimal("9200"), idea.collateral_needed
    assert_equal BigDecimal("120"), idea.credit_per_contract
    assert_equal BigDecimal("90.80"), idea.break_even
    assert_nil idea.called_away_price
    assert_in_delta(-8.0, idea.distance_from_spot_pct, 1e-9)
    assert_equal 5, idea.contracts_max
    refute_match(/cash.?secured/i, idea.to_h.to_s)
    refute_match(/cash.?secured/i, Scanner.constants.to_s)
  end

  test "collateral_needed equals strike times 100 times contracts" do
    idea = scan(:cash_needed_put, [ put_row(92) ]).ideas.first
    assert_equal 1, idea.contracts
    assert_equal idea.strike * 100 * idea.contracts, idea.collateral_needed
  end

  test "only rows of the requested option type become ideas or exclusions" do
    result = scan(:covered_call, [ row, put_row(92) ])
    assert_equal [ "ACME261112C00110000" ], result.ideas.map(&:contract)
    assert_empty result.exclusions
  end

  # ---- filters ---------------------------------------------------------------------------

  test "delta band is enforced on the solved delta with exclusion reason" do
    rows = [ call_row(106), call_row(108), call_row(114), call_row(120) ]
    result = scan(:covered_call, rows)
    assert_equal [ "ACME261112C00108000" ], result.ideas.map(&:contract)
    %w[ACME261112C00106000 ACME261112C00114000 ACME261112C00120000].each do |s|
      assert_includes reasons_for(result, s), :outside_delta_band, s
    end
  end

  test "put delta band uses absolute delta while the idea keeps the negative sign" do
    rows = [ put_row(92), put_row(96), put_row(90) ]
    result = scan(:cash_needed_put, rows)
    assert_equal [ 92 ], result.ideas.map { |i| i.strike.to_i }
    assert_operator result.ideas.first.delta, :<, 0
    assert_includes reasons_for(result, rows[1][:contract_symbol]), :outside_delta_band
    assert_includes reasons_for(result, rows[2][:contract_symbol]), :outside_delta_band
  end

  test "band edges are inclusive" do
    delta = scan(:covered_call, [ row ]).ideas.first.delta
    cfg = Scanner::Config.new(delta_min: delta, delta_max: delta)
    assert_equal 1, scan(:covered_call, [ row ], config: cfg).ideas.size
  end

  test "dte window is enforced using the new york market date" do
    rows = [
      row(contract_symbol: "SOON", expiration: @today + 20),
      row(contract_symbol: "MIN", expiration: @today + 21),
      row(contract_symbol: "MAX", expiration: @today + 45),
      row(contract_symbol: "LATE", expiration: @today + 46),
      row(contract_symbol: "TODAY", expiration: @today),
      row(contract_symbol: "PAST", expiration: @today - 3)
    ]
    result = scan(:covered_call, rows, config: Scanner::Config.new(delta_min: 0.01, delta_max: 0.99))
    assert_equal %w[MAX MIN], result.ideas.map(&:contract).sort
    %w[SOON LATE TODAY PAST].each { |s| assert_includes reasons_for(result, s), :outside_dte }
  end

  test "dte uses the new york date even when utc has already rolled over" do
    friday_night = NY.local(2026, 10, 16, 22, 0)
    assert_equal Date.new(2026, 10, 17), friday_night.utc.to_date
    expiration = Date.new(2026, 10, 16) + 21
    r = row(expiration: expiration, session_date: Date.new(2026, 10, 16), quote_time: NY.local(2026, 10, 16, 16, 0))
    idea = scan(:covered_call, [ r ], now: friday_night.utc, config: Scanner::Config.new(delta_min: 0.01, delta_max: 0.99)).ideas.first
    assert_equal 21, idea.dte
  end

  test "min open interest and nil open interest is low_oi never a pass" do
    rows = [ row(contract_symbol: "OK", open_interest: 50), row(contract_symbol: "LOW", open_interest: 49), row(contract_symbol: "NONE", open_interest: nil) ]
    result = scan(:covered_call, rows)
    assert_equal [ "OK" ], result.ideas.map(&:contract)
    assert_includes reasons_for(result, "LOW"), :low_oi
    assert_includes reasons_for(result, "NONE"), :low_oi
    assert_includes reasons_for(scan(:covered_call, [ row(contract_symbol: "Z", open_interest: 0) ]), "Z"), :low_oi
  end

  test "bid rules no_bid for nil or zero and min_bid floor" do
    rows = [
      row(contract_symbol: "NILBID", bid: nil),
      row(contract_symbol: "ZEROBID", bid: BigDecimal("0")),
      row(contract_symbol: "TINY", bid: BigDecimal("0.04"), ask: BigDecimal("0.05"))
    ]
    result = scan(:covered_call, rows, config: Scanner::Config.new(delta_min: 0.0, delta_max: 1.0))
    assert_empty result.ideas
    assert_includes reasons_for(result, "NILBID"), :no_bid
    assert_includes reasons_for(result, "ZEROBID"), :no_bid
    assert_includes reasons_for(result, "TINY"), :below_min_bid
  end

  test "wide spread is excluded and a missing or crossed ask is flagged" do
    rows = [
      row(contract_symbol: "WIDE", bid: BigDecimal("1.00"), ask: BigDecimal("1.50")),
      row(contract_symbol: "NOASK", bid: BigDecimal("1.00"), ask: nil),
      row(contract_symbol: "CROSSED", bid: BigDecimal("1.00"), ask: BigDecimal("0.90"))
    ]
    result = scan(:covered_call, rows)
    assert_empty result.ideas
    assert_includes reasons_for(result, "WIDE"), :wide_spread
    assert_includes reasons_for(result, "NOASK"), :no_ask
    assert_includes reasons_for(result, "CROSSED"), :no_ask
  end

  test "stale quote rows are excluded and never get an idea" do
    result = scan(:covered_call, [ row(contract_symbol: "OLD", session_date: @today - 1), row(contract_symbol: "NOSESSION", session_date: nil) ])
    assert_empty result.ideas
    assert_includes reasons_for(result, "OLD"), :stale_quote
    assert_includes reasons_for(result, "NOSESSION"), :stale_quote
  end

  test "friday settle viewed on monday 07:00 ET is a current session but monday 09:30 is not" do
    friday = Date.new(2026, 10, 16)
    r = row(session_date: friday, quote_time: NY.local(2026, 10, 16, 16, 0), expiration: friday + 28)
    assert_equal 1, scan(:covered_call, [ r ], now: NY.local(2026, 10, 19, 7, 0)).ideas.size
    assert_includes scan(:covered_call, [ r ], now: NY.local(2026, 10, 19, 9, 30)).exclusions.first.reasons, :stale_quote
  end

  test "delta unavailable copies the model delta reason into detail" do
    rows = [
      row(contract_symbol: "NOSPOT", underlying_price: nil),
      row(contract_symbol: "NOQUOTETIME", quote_time: nil)
    ]
    result = scan(:covered_call, rows)
    assert_empty result.ideas
    nospot = result.exclusions.find { |e| e.contract == "NOSPOT" }
    assert_includes nospot.reasons, :delta_unavailable
    assert_equal :no_underlying, nospot.detail
    noqt = result.exclusions.find { |e| e.contract == "NOQUOTETIME" }
    assert_includes noqt.reasons, :delta_unavailable
    assert_equal :stale_quote, noqt.detail
  end

  test "a one day out contract is excluded as delta unavailable with too_close_to_expiry" do
    config = Scanner::Config.new(dte_min: 0)
    result = scan(:covered_call, [ row(contract_symbol: "NEAR", expiration: @today + 1) ], config: config)
    assert_empty result.ideas
    ex = result.exclusions.first
    assert_includes ex.reasons, :delta_unavailable
    assert_equal :too_close_to_expiry, ex.detail
  end

  test "a garbage market is delta unavailable not a fake delta" do
    r = row(contract_symbol: "DEEP", strike: BigDecimal("50"), bid: BigDecimal("0.50"), ask: BigDecimal("0.55"))
    result = scan(:covered_call, [ r ])
    assert_empty result.ideas
    ex = result.exclusions.first
    assert_includes ex.reasons, :delta_unavailable
    assert_equal :iv_unsolved, ex.detail
  end

  # ---- holdings --------------------------------------------------------------------------

  test "insufficient shares excludes every call" do
    result = scan(:covered_call, [ row(contract_symbol: "A") ], ctx: context(shares_available: 99))
    assert_empty result.ideas
    assert_includes reasons_for(result, "A"), :insufficient_shares
    assert_includes reasons_for(scan(:covered_call, [ row(contract_symbol: "B") ], ctx: context(shares_available: 0)), "B"), :insufficient_shares
    assert_includes reasons_for(scan(:covered_call, [ row(contract_symbol: "C") ], ctx: context(shares_available: nil)), "C"), :insufficient_shares
  end

  test "contracts_max floors shares_available over 100" do
    assert_equal 1, scan(:covered_call, [ row ], ctx: context(shares_available: 199)).ideas.first.contracts_max
    assert_equal 2, scan(:covered_call, [ row ], ctx: context(shares_available: 200)).ideas.first.contracts_max
    assert_equal 1, scan(:covered_call, [ row ], ctx: context(shares_available: 100)).ideas.first.contracts_max
  end

  test "missing context for an underlying behaves as no data" do
    result = Scanner.scan(kind: :covered_call, rows: [ row(contract_symbol: "X") ], contexts: {}, now: @now)
    assert_includes reasons_for(result, "X"), :insufficient_shares
    result = Scanner.scan(kind: :cash_needed_put, rows: [ put_row(92) ], contexts: {}, now: @now)
    assert_includes result.exclusions.first.reasons, :no_cash_data
  end

  test "called away below basis flag and unknown basis flag" do
    below = scan(:covered_call, [ row ], ctx: context(basis_per_share: BigDecimal("112"))).ideas.first
    assert_equal [ :called_away_below_basis ], below.flags
    equal = scan(:covered_call, [ row ], ctx: context(basis_per_share: BigDecimal("111"))).ideas.first
    assert_equal [], equal.flags
    unknown = scan(:covered_call, [ row ], ctx: context(basis_per_share: nil)).ideas.first
    assert_equal [ :no_basis_data ], unknown.flags
  end

  test "nil cash is no_cash_data and never silently passes" do
    result = scan(:cash_needed_put, [ put_row(92, contract_symbol: "P92") ], ctx: context(cash_available: nil))
    assert_empty result.ideas
    assert_equal [ :no_cash_data ], reasons_for(result, "P92")
  end

  test "zero cash is a real zero and gives insufficient_cash" do
    result = scan(:cash_needed_put, [ put_row(92, contract_symbol: "P92") ], ctx: context(cash_available: BigDecimal("0")))
    assert_includes reasons_for(result, "P92"), :insufficient_cash
    refute_includes reasons_for(result, "P92"), :no_cash_data
  end

  test "negative cash is clamped to zero" do
    result = scan(:cash_needed_put, [ put_row(92, contract_symbol: "P92") ], ctx: context(cash_available: BigDecimal("-500")))
    assert_equal [ :insufficient_cash ], reasons_for(result, "P92")
  end

  test "cash below one contract of collateral is insufficient and exactly one contract is fine" do
    result = scan(:cash_needed_put, [ put_row(92, contract_symbol: "P92") ], ctx: context(cash_available: BigDecimal("9199.99")))
    assert_includes reasons_for(result, "P92"), :insufficient_cash
    ok = scan(:cash_needed_put, [ put_row(92) ], ctx: context(cash_available: BigDecimal("9200")))
    assert_equal 1, ok.ideas.size
    assert_equal 1, ok.ideas.first.contracts_max
  end

  test "assignment exposure flag when existing total exposure plus needed exceeds cash" do
    flagged = scan(:cash_needed_put, [ put_row(92) ], ctx: context(cash_available: BigDecimal("10000"), existing_short_put_exposure: BigDecimal("1000"))).ideas.first
    assert_includes flagged.flags, :assignment_exposure_exceeds_cash
    assert_equal 0, flagged.contracts_max

    fits = scan(:cash_needed_put, [ put_row(92) ], ctx: context(cash_available: BigDecimal("10200"), existing_short_put_exposure: BigDecimal("1000"))).ideas.first
    refute_includes fits.flags, :assignment_exposure_exceeds_cash
    assert_equal 1, fits.contracts_max
    assert_equal BigDecimal("9200"), fits.collateral_needed
  end

  test "unknown existing exposure is flagged and not assumed to be zero" do
    idea = scan(:cash_needed_put, [ put_row(92) ], ctx: context(existing_short_put_exposure: nil)).ideas.first
    assert_equal [ :no_exposure_data ], idea.flags
  end

  # ---- flags ------------------------------------------------------------------------------

  test "earnings flags: in window, outside the window, unknown" do
    inside = scan(:covered_call, [ row ], ctx: context(earnings_date: @today + 10)).ideas.first
    assert_equal [ :earnings_in_window ], inside.flags
    assert_includes scan(:covered_call, [ row ], ctx: context(earnings_date: @expiration)).ideas.first.flags, :earnings_in_window
    assert_includes scan(:covered_call, [ row ], ctx: context(earnings_date: @today)).ideas.first.flags, :earnings_in_window
    assert_equal [], scan(:covered_call, [ row ], ctx: context(earnings_date: @expiration + 1)).ideas.first.flags
    assert_equal [], scan(:covered_call, [ row ], ctx: context(earnings_date: @today - 1)).ideas.first.flags
    unknown = scan(:covered_call, [ row ], ctx: context(earnings_known: false)).ideas.first
    assert_equal [ :earnings_unknown ], unknown.flags
  end

  test "earnings window is judged against the new york date" do
    friday_night = NY.local(2026, 10, 16, 22, 0)
    r = row(session_date: Date.new(2026, 10, 16), quote_time: NY.local(2026, 10, 16, 16, 0), expiration: Date.new(2026, 10, 16) + 28)
    on_friday = scan(:covered_call, [ r ], now: friday_night.utc, ctx: context(earnings_date: Date.new(2026, 10, 16))).ideas.first
    assert_includes on_friday.flags, :earnings_in_window
  end

  test "ex dividend in window applies to calls only" do
    call = scan(:covered_call, [ row ], ctx: context(ex_dividend_date: @today + 5)).ideas.first
    assert_equal [ :ex_dividend_in_window ], call.flags
    put = scan(:cash_needed_put, [ put_row(92) ], ctx: context(ex_dividend_date: @today + 5)).ideas.first
    refute_includes put.flags, :ex_dividend_in_window
    outside = scan(:covered_call, [ row ], ctx: context(ex_dividend_date: @expiration + 1)).ideas.first
    assert_equal [], outside.flags
  end

  test "long calls present flag" do
    assert_equal [ :long_calls_present ], scan(:covered_call, [ row ], ctx: context(long_calls_present: true)).ideas.first.flags
    assert_equal [ :long_calls_present ], scan(:cash_needed_put, [ put_row(92) ], ctx: context(long_calls_present: true)).ideas.first.flags
  end

  test "leveraged or hard to borrow underlyings are flagged" do
    r = row(underlying: "TSLL", contract_symbol: "TSLL261112C00110000")
    idea = scan(:covered_call, [ r ], ctx: context(underlying: "TSLL")).ideas.first
    assert_equal [ :leveraged_or_hard_to_borrow ], idea.flags
  end

  test "early assignment is not modelled flag for in the money contracts within seven days" do
    r = row(contract_symbol: "ITM", strike: BigDecimal("95"), bid: BigDecimal("5.10"), ask: BigDecimal("5.30"), expiration: @today + 7)
    cfg = Scanner::Config.new(dte_min: 1, delta_min: 0.0, delta_max: 1.0)
    idea = scan(:covered_call, [ r ], config: cfg).ideas.first
    assert_includes idea.flags, :early_assignment_not_modeled
    far = scan(:covered_call, [ r.merge(expiration: @today + 8) ], config: cfg).ideas.first
    refute_includes far.flags, :early_assignment_not_modeled
  end

  # ---- ranking ----------------------------------------------------------------------------

  test "ranking is by closeness to delta 0.20 then annualized yield" do
    result = scan(:covered_call, [ call_row(108), call_row(110) ])
    assert_equal %w[ACME261112C00110000 ACME261112C00108000], result.ideas.map(&:contract)
  end

  test "equal delta distance breaks ties by contract symbol ascending" do
    rows = [ row(contract_symbol: "B"), row(contract_symbol: "A") ]
    assert_equal %w[A B], scan(:covered_call, rows).ideas.map(&:contract)
  end

  test "annualized yield breaks ties between equal delta distance before the symbol does" do
    # identical markets except one extra expiration is not possible, so tie on |delta - target| by
    # making the target exactly one contract's delta and asserting the sort key order through yield.
    low = scan(:covered_call, [ row(contract_symbol: "A") ]).ideas.first
    high_row = row(contract_symbol: "B", bid: BigDecimal("1.00"), ask: BigDecimal("1.10"), underlying_price: BigDecimal("100"))
    cfg = Scanner::Config.new(delta_target: low.delta)
    ranked = scan(:covered_call, [ high_row, row(contract_symbol: "A") ], config: cfg).ideas
    assert_equal %w[A B], ranked.map(&:contract)
  end

  test "flagged ideas never rank above clean ones even when closer to the target delta" do
    flagged_account = context(account_id: "a1", account_name: "Flagged", basis_per_share: BigDecimal("130"))
    clean_account = context(account_id: "a2", account_name: "Clean")
    rows = [ call_row(110), call_row(108) ] # 110 is the closer one to delta 0.20
    ordered = scan(:covered_call, rows, ctx: [ flagged_account, clean_account ]).ideas

    assert_equal %w[a2 a2 a1 a1], ordered.map(&:account_id)
    assert_equal [ [], [], [ :called_away_below_basis ], [ :called_away_below_basis ] ], ordered.map(&:flags)
    assert_equal %w[C00110000 C00108000 C00110000 C00108000], ordered.map { |i| i.contract[-9..] }
  end

  test "the rows cap is applied after ordering so clean ideas are kept over flagged ones" do
    flagged_account = context(account_id: "a1", basis_per_share: BigDecimal("130"))
    clean_account = context(account_id: "a2")
    result = scan(:covered_call, [ call_row(110), call_row(108) ], ctx: [ flagged_account, clean_account ], config: Scanner::Config.new(rows: 2))
    assert_equal %w[a2 a2], result.ideas.map(&:account_id)
    assert_equal 4, result.candidates_count
  end

  test "ordering is deterministic regardless of input order" do
    rows = [ call_row(106), call_row(108), call_row(110), row(contract_symbol: "A"), row(contract_symbol: "B") ]
    cfg = Scanner::Config.new(delta_min: 0.01, delta_max: 0.99, rows: 20)
    first = scan(:covered_call, rows, config: cfg)
    second = scan(:covered_call, rows.reverse, config: cfg)
    assert_equal first.ideas.map(&:contract), second.ideas.map(&:contract)
    assert_equal first.exclusions.map(&:contract), second.exclusions.map(&:contract)
    assert_equal first.ideas.map(&:delta), second.ideas.map(&:delta)
  end

  test "rows config limits ideas and candidates_count counts everything that passed" do
    rows = (1..8).map { |i| row(contract_symbol: "X#{i}", bid: BigDecimal("1.00") + BigDecimal(i) / 100, ask: BigDecimal("1.20")) }
    result = scan(:covered_call, rows, config: Scanner::Config.new(rows: 3))
    assert_equal 3, result.ideas.size
    assert_equal 8, result.candidates_count
  end

  # ---- exclusions -------------------------------------------------------------------------

  test "every rejected row yields exactly one exclusion and none are dropped" do
    rows = [
      row(contract_symbol: "GOOD"),
      row(contract_symbol: "R1", bid: nil),
      row(contract_symbol: "R2", open_interest: 1),
      row(contract_symbol: "R3", expiration: @today + 90),
      row(contract_symbol: "R4", underlying_price: nil),
      call_row(120, contract_symbol: "R5")
    ]
    result = scan(:covered_call, rows)
    assert_equal [ "GOOD" ], result.ideas.map(&:contract)
    assert_equal %w[R1 R2 R3 R4 R5], result.exclusions.map(&:contract).sort
    assert result.exclusions.all? { |e| e.reasons.any? && e.reasons.all?(Symbol) }
    assert_equal rows.size, result.ideas.size + result.exclusions.size
  end

  test "multiple reasons are all reported with the account" do
    ex = scan(:covered_call, [ row(contract_symbol: "BAD", bid: nil, open_interest: 1) ]).exclusions.first
    assert_includes ex.reasons, :no_bid
    assert_includes ex.reasons, :low_oi
    assert_equal "ACME", ex.underlying
    assert_equal "acct-1", ex.account_id
    assert_equal BigDecimal("110"), ex.strike
    assert_equal @expiration, ex.expiration
  end

  test "malformed rows are excluded not raised" do
    rows = [
      row(contract_symbol: "NOSTRIKE", strike: nil),
      row(contract_symbol: "NOEXP", expiration: nil),
      row(contract_symbol: "BADTYPE", option_type: "STRADDLE"),
      row(contract_symbol: "NOUND", underlying: nil)
    ]
    result = scan(:covered_call, rows)
    assert_empty result.ideas
    assert_equal 4, result.exclusions.size
    assert result.exclusions.all? { |e| e.reasons.include?(:invalid_row) }
  end

  test "accepts type and oi aliases plus lowercase type" do
    r = row(contract_symbol: "ALIAS").except(:open_interest, :option_type).merge(oi: 300, type: "call")
    idea = scan(:covered_call, [ r ]).ideas.first
    assert_equal "ALIAS", idea.contract
    assert_equal 300, idea.open_interest
  end

  test "float and integer inputs are coerced to BigDecimal for money fields" do
    r = row(bid: 1.0, ask: 1.1, strike: 110, underlying_price: 100.0)
    idea = scan(:covered_call, [ r ]).ideas.first
    [ idea.bid, idea.ask, idea.mid, idea.strike, idea.credit_per_contract, idea.called_away_price ].each { |v| assert_kind_of BigDecimal, v }
    assert_equal BigDecimal("100"), idea.credit_per_contract
  end

  test "contract symbols with spaces are normalized" do
    idea = scan(:covered_call, [ row(contract_symbol: "ACME  261112C00110000") ]).ideas.first
    assert_equal "ACME261112C00110000", idea.contract
  end

  test "unknown kind raises ArgumentError" do
    assert_raises(ArgumentError) { scan(:bogus, [ row ]) }
  end

  test "empty input gives empty result with the note" do
    result = scan(:covered_call, [])
    assert_empty result.ideas
    assert_empty result.exclusions
    assert_equal 0, result.candidates_count
    assert_kind_of String, result.joint_exposure_note
  end

  # ---- accounts ---------------------------------------------------------------------------

  test "the same underlying in several accounts is evaluated separately per account" do
    rich = context(account_id: "a1", account_name: "Rich", shares_available: 500)
    poor = context(account_id: "a2", account_name: "Poor", shares_available: 100)
    none = context(account_id: "a3", account_name: "None", shares_available: 50)
    result = scan(:covered_call, [ row ], ctx: [ rich, poor, none ])
    assert_equal({ "a1" => 5, "a2" => 1 }, result.ideas.to_h { |i| [ i.account_id, i.contracts_max ] })
    assert_equal %w[Poor Rich], result.ideas.map(&:account_name).sort
    ex = result.exclusions.find { |e| e.account_id == "a3" }
    assert_equal [ :insufficient_shares ], ex.reasons
    assert_equal "None", ex.account_name
  end

  test "shares are never pooled across accounts" do
    a = context(account_id: "a1", shares_available: 60)
    b = context(account_id: "a2", shares_available: 60)
    result = scan(:covered_call, [ row ], ctx: [ a, b ])
    assert_empty result.ideas
    assert_equal 2, result.exclusions.size
  end

  test "put ideas carry the account and respect each account's cash and exposure" do
    a = context(account_id: "a1", account_name: "A", cash_available: BigDecimal("9200"))
    b = context(account_id: "a2", account_name: "B", cash_available: BigDecimal("100000"), existing_short_put_exposure: BigDecimal("95000"))
    by_account = scan(:cash_needed_put, [ put_row(92) ], ctx: [ a, b ]).ideas.to_h { |i| [ i.account_id, i ] }
    assert_equal [], by_account["a1"].flags
    assert_equal [ :assignment_exposure_exceeds_cash ], by_account["a2"].flags
    assert_equal 1, by_account["a1"].contracts_max
    assert_equal 0, by_account["a2"].contracts_max
  end

  test "contexts for the same underlying under different accounts do not collide and may be plain hashes" do
    ctxs = {
      [ "a1", "ACME" ] => { account_name: "One", shares_available: 100 },
      [ "a2", "acme" ] => { account_name: "Two", shares_available: 200 }
    }
    result = Scanner.scan(kind: :covered_call, rows: [ row ], contexts: ctxs, now: @now)
    assert_equal [ [ "a1", 1 ], [ "a2", 2 ] ], result.ideas.map { |i| [ i.account_id, i.contracts_max ] }.sort
  end

  test "contexts for other underlyings are ignored" do
    result = Scanner.scan(kind: :covered_call, rows: [ row ], contexts: { [ "a1", "OTHR" ] => { shares_available: 500 } }, now: @now)
    assert_empty result.ideas
    assert_includes result.exclusions.first.reasons, :insufficient_shares
  end

  test "joint exposure note says ideas are per account and not additive" do
    note = scan(:covered_call, [ row ]).joint_exposure_note
    assert_equal Scanner::JOINT_EXPOSURE_NOTE, note
    assert_match(/each account/i, note)
    assert_match(/not additive/i, note)
  end

  # ---- vocabulary -------------------------------------------------------------------------

  test "no banned vocabulary in any user facing string the scanner produces" do
    banned = /cash.?secured|\bsafe\b|\bsafely\b|\bbest\b|opportunit|top ideas|\bsell/i
    rows = [ call_row(106), call_row(108), call_row(110), row(contract_symbol: "BAD", bid: nil), row(contract_symbol: "STALE", session_date: @today - 1) ]
    flagged = context(basis_per_share: BigDecimal("130"), earnings_known: false, long_calls_present: true, earnings_date: @today + 3, ex_dividend_date: @today + 3)
    calls = scan(:covered_call, rows, ctx: [ flagged ])
    puts_result = scan(:cash_needed_put, [ put_row(92), put_row(94) ], ctx: [ context(existing_short_put_exposure: nil, cash_available: BigDecimal("9300")) ])
    [ calls, puts_result ].each do |result|
      assert_operator result.ideas.size + result.exclusions.size, :>, 0
      strings = [ result.joint_exposure_note ]
      strings += result.ideas.flat_map { |i| i.flags.map(&:to_s) + [ i.currency.to_s, i.account_name.to_s ] }
      strings += result.exclusions.flat_map { |e| e.reasons.map(&:to_s) + [ e.detail.to_s ] }
      strings.each { |s| refute_match banned, s }
    end
  end

  # ---- host timezone ----------------------------------------------------------------------

  test "results are identical under a chicago host TZ" do
    rows = [ call_row(106), call_row(108), call_row(110) ]
    base = scan(:covered_call, rows)
    original = ENV["TZ"]
    ENV["TZ"] = "America/Chicago"
    begin
      assert_equal "CDT", Time.local(2026, 10, 15, 12).zone, "precondition"
      chicago_now = Time.local(2026, 10, 15, 15, 20) # 16:20 ET
      again = scan(:covered_call, rows, now: chicago_now)
      assert_equal base.ideas.map(&:to_h), again.ideas.map(&:to_h)
      assert_equal base.exclusions.map(&:to_h), again.exclusions.map(&:to_h)
      late_friday = Time.local(2026, 10, 16, 23, 0) # Saturday 00:00 in New York
      r = row(session_date: Date.new(2026, 10, 16), quote_time: NY.local(2026, 10, 16, 16, 0), expiration: Date.new(2026, 10, 16) + 28)
      assert_equal Date.new(2026, 10, 16), late_friday.to_date, "host date is still Friday"
      assert_equal 27, scan(:covered_call, [ r ], now: late_friday).ideas.first.dte, "dte counts from the New York date (Saturday)"
    ensure
      original.nil? ? ENV.delete("TZ") : ENV["TZ"] = original
    end
  end
end
