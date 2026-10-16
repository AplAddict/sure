# Research-only covered-call / short-put idea scanner. Pure function over plain hashes: no DB, no network.
#
#   Options::IdeaScanner.scan(kind: :covered_call | :cash_needed_put,
#                             rows: [Hash],                 # keys mirror option_quotes columns, see normalize
#                             contexts: { [account_id, "NVDA"] => Context | Hash },
#                             config: Config.new, now: Time)
#   # => Result(ideas:, exclusions:, candidates_count:, joint_exposure_note:)
#
# Every (row, account context) pair is evaluated on its own and is never pooled with another account: ideas
# are per account and non-additive. Delta is model delta from OUR implied vol (Options::ModelDelta), never
# the row's Yahoo IV. Every row of the requested option type that does not become an idea comes back as an
# Exclusion with reasons (nothing is dropped silently). Ideas are ranked, never recommended; flagged ideas
# never rank above unflagged ones. User-facing strings avoid recommendation vocabulary and any claim of
# verified collateral.
module Options::IdeaScanner
  KINDS = { covered_call: "CALL", cash_needed_put: "PUT" }.freeze
  MULTIPLIER = 100
  DAYS_PER_YEAR = 365

  JOINT_EXPOSURE_NOTE = "Ideas are calculated separately for each account and are not additive. " \
                        "The same shares or cash can appear under more than one account; " \
                        "nothing is pooled or netted across accounts.".freeze

  Config = Struct.new(
    :delta_min, :delta_max, :delta_target, :dte_min, :dte_max, :min_open_interest,
    :max_spread_pct, :min_bid, :rows, keyword_init: true
  ) do
    def initialize(**overrides)
      super(**{
        delta_min: 0.15, delta_max: 0.30, delta_target: 0.20, dte_min: 21, dte_max: 45,
        min_open_interest: 50, max_spread_pct: 0.25, min_bid: BigDecimal("0.05"), rows: 5
      }.merge(overrides))
    end
  end

  # shares_available: Integer, already net of ALL short calls on the underlying in this account.
  # cash_available: BigDecimal or nil (unknown / currency mismatch); negatives are clamped to 0.
  # existing_short_put_exposure: BigDecimal, TOTAL strike x 100 x contracts across all short puts in the account.
  # Unknown values stay nil and are flagged, never defaulted to a comfortable number.
  Context = Struct.new(
    :account_id, :account_name, :underlying, :shares_available, :cash_available, :existing_short_put_exposure,
    :currency, :basis_per_share, :long_calls_present, :earnings_date, :earnings_known, :ex_dividend_date,
    keyword_init: true
  )

  Idea = Struct.new(
    :kind, :account_id, :account_name, :underlying, :contract, :contract_symbol, :expiration, :dte, :strike, :bid, :ask, :mid,
    :delta, :iv, :open_interest, :credit_per_contract, :contracts, :contracts_max, :annualized_yield_pct,
    :break_even, :called_away_price, :distance_from_spot_pct, :collateral_needed, :currency, :quote_time, :flags,
    keyword_init: true
  )

  Exclusion = Struct.new(
    :kind, :account_id, :account_name, :underlying, :contract, :option_type, :expiration, :strike, :reasons, :detail,
    keyword_init: true
  )

  Result = Struct.new(:ideas, :exclusions, :candidates_count, :joint_exposure_note, keyword_init: true)

  module_function

  def scan(kind:, rows:, contexts:, config: Config.new, now: Time.now)
    option_type = KINDS[kind] or raise ArgumentError, "unknown kind #{kind.inspect}; use #{KINDS.keys.inspect}"
    by_underlying = index_contexts(contexts)
    today = Options::MarketCalendar.market_date(now)
    session = Options::MarketCalendar.latest_session(now)

    ideas = []
    exclusions = []

    Array(rows).each do |raw|
      row = normalize(raw)
      next if KINDS.value?(row[:option_type]) && row[:option_type] != option_type

      unless valid_row?(row)
        exclusions << exclusion(kind, row, nil, [ :invalid_row ])
        next
      end

      (by_underlying[row[:underlying]] || [ blank_context(row[:underlying]) ]).each do |context|
        evaluation = evaluate(kind, row, context, config, now, today, session)
        if evaluation[:reasons].any?
          exclusions << exclusion(kind, row, context, evaluation[:reasons], evaluation[:detail])
        else
          ideas << build_idea(kind, row, context, evaluation[:dte], evaluation[:model], today)
        end
      end
    end

    ranked = ideas.sort_by { |i| rank_key(i, config) }
    Result.new(
      ideas: ranked.first(config.rows),
      exclusions: exclusions.sort_by { |e| [ e.contract.to_s, e.account_id.to_s, e.expiration.to_s, e.strike.to_s ] },
      candidates_count: ideas.size,
      joint_exposure_note: JOINT_EXPOSURE_NOTE
    )
  end

  # Unflagged first, then flagged; within a group by |delta - target|, yield desc, contract asc.
  def rank_key(idea, config)
    [ idea.flags.empty? ? 0 : 1, (idea.delta.abs - config.delta_target).abs.round(6), -idea.annualized_yield_pct,
      idea.contract.to_s, idea.account_id.to_s ]
  end

  def evaluate(kind, row, context, config, now, today, session)
    reasons = []
    detail = nil
    dte = (row[:expiration] - today).to_i
    bid, ask = row[:bid], row[:ask]

    if bid.nil? || bid <= 0
      reasons << :no_bid
    elsif bid < config.min_bid
      reasons << :below_min_bid
    end

    if ask.nil? || ask <= 0 || (bid && ask < bid)
      reasons << :no_ask
    elsif bid && bid > 0 && (ask - bid) / ((ask + bid) / 2) > BigDecimal(config.max_spread_pct.to_s)
      reasons << :wide_spread
    end

    reasons << :stale_quote unless row[:session_date] == session
    reasons << :low_oi if row[:open_interest].nil? || row[:open_interest] < config.min_open_interest

    model = nil
    if dte < [ config.dte_min, 1 ].max || dte > config.dte_max
      reasons << :outside_dte
    else
      model = Options::ModelDelta.compute(row: model_row(row), now: now)
      if model.value.nil?
        reasons << :delta_unavailable
        detail = model.reason
      elsif model.value.abs < config.delta_min || model.value.abs > config.delta_max
        reasons << :outside_delta_band
      end
    end

    reasons.concat(holdings_reasons(kind, row, context))
    { reasons: reasons.uniq, detail: detail, dte: dte, model: model }
  end

  def model_row(row)
    row.slice(:option_type, :strike, :expiration, :bid, :ask, :quote_time, :session_date).merge(underlying_price: row[:spot])
  end

  def normalize(raw)
    r = raw.to_h.transform_keys(&:to_sym)
    {
      underlying: r[:underlying].to_s.strip.upcase.presence,
      contract: r[:contract_symbol].to_s.gsub(/\s+/, "").upcase.presence,
      option_type: (r[:option_type] || r[:type]).to_s.strip.upcase.presence,
      strike: Options::Values.decimal(r[:strike]),
      expiration: date(r[:expiration]),
      spot: Options::Values.decimal(r[:underlying_price]),
      bid: Options::Values.decimal(r[:bid]),
      ask: Options::Values.decimal(r[:ask]),
      open_interest: integer(r.key?(:open_interest) ? r[:open_interest] : r[:oi]),
      quote_time: r[:quote_time],
      session_date: date(r[:session_date])
    }
  end

  def valid_row?(row)
    row[:underlying] && KINDS.value?(row[:option_type]) && row[:strike]&.positive? && row[:expiration] ? true : false
  end

  def holdings_reasons(kind, row, context)
    if kind == :covered_call
      shares = context.shares_available
      return shares.nil? || shares < MULTIPLIER ? [ :insufficient_shares ] : []
    end

    cash = clamped_cash(context)
    return [ :no_cash_data ] if cash.nil?

    cash < row[:strike] * MULTIPLIER ? [ :insufficient_cash ] : []
  end

  def clamped_cash(context)
    cash = Options::Values.decimal(context.cash_available)
    cash && cash.negative? ? BigDecimal("0") : cash
  end

  def build_idea(kind, row, context, dte, model, today)
    bid = row[:bid]
    strike = row[:strike]
    call = kind == :covered_call
    collateral = call ? nil : strike * MULTIPLIER
    flags = []

    if call
      called_away = strike + bid
      contracts_max = (context.shares_available / MULTIPLIER).floor
      flags << if (basis = Options::Values.decimal(context.basis_per_share)).nil? then :no_basis_data
      elsif called_away < basis then :called_away_below_basis
      end
      flags << :ex_dividend_in_window if in_window?(context.ex_dividend_date, today, row[:expiration])
    else
      cash = clamped_cash(context)
      exposure = Options::Values.decimal(context.existing_short_put_exposure)
      flags << :no_exposure_data if exposure.nil?
      exposure ||= BigDecimal("0")
      flags << :assignment_exposure_exceeds_cash if exposure + collateral > cash
      contracts_max = [ ((cash - exposure) / collateral).floor, 0 ].max
    end

    flags << :long_calls_present if context.long_calls_present == true
    flags.concat(earnings_flags(context, today, row[:expiration]))
    itm = call ? strike < row[:spot] : strike > row[:spot]
    flags.concat(Options::Caveats.for(underlying: row[:underlying], itm: itm, dte: dte) & %i[leveraged_or_hard_to_borrow early_assignment_not_modeled])

    Idea.new(
      kind: kind, account_id: context.account_id, account_name: context.account_name, underlying: row[:underlying],
      contract: row[:contract], contract_symbol: row[:contract], expiration: row[:expiration], dte: dte, strike: strike, bid: bid, ask: row[:ask],
      mid: (bid + row[:ask]) / 2, delta: model.value, iv: model.iv, open_interest: row[:open_interest],
      credit_per_contract: bid * MULTIPLIER, contracts: 1, contracts_max: contracts_max,
      annualized_yield_pct: annualized_yield(bid, call ? row[:spot] : strike, dte),
      break_even: call ? nil : strike - bid, called_away_price: call ? called_away : nil,
      distance_from_spot_pct: ((strike - row[:spot]) * 100).div(row[:spot], 16).round(4),
      collateral_needed: collateral, currency: context.currency, quote_time: row[:quote_time], flags: flags.compact.uniq
    )
  end

  # Simple (not compounded): puts bid / strike, calls bid / spot, scaled by 365 / dte.
  def annualized_yield(bid, base, dte)
    (bid.div(base, 20) * DAYS_PER_YEAR * 100).div(dte, 20).round(4)
  end

  def earnings_flags(context, today, expiration)
    flags = []
    flags << :earnings_in_window if in_window?(context.earnings_date, today, expiration)
    flags << :earnings_unknown unless context.earnings_known == true
    flags
  end

  def in_window?(value, today, expiration)
    day = date(value)
    !day.nil? && day >= today && day <= expiration
  end

  def exclusion(kind, row, context, reasons, detail = nil)
    Exclusion.new(
      kind: kind, account_id: context&.account_id, account_name: context&.account_name, underlying: row[:underlying],
      contract: row[:contract], option_type: row[:option_type], expiration: row[:expiration], strike: row[:strike],
      reasons: reasons.uniq, detail: detail
    )
  end

  # { "NVDA" => [Context, ...] } with accounts in a stable order. Accepts a Hash keyed by
  # [account_id, underlying] (a bare underlying key means no account) or an Array of contexts.
  def index_contexts(contexts)
    entries = contexts.respond_to?(:each_pair) ? contexts.map { |key, value| [ key, value ] } : Array(contexts).map { |value| [ nil, value ] }
    entries.map { |key, value| coerce_context(key, value) }
           .group_by(&:underlying)
           .transform_values { |list| list.sort_by { |c| [ c.account_id.to_s, c.account_name.to_s ] } }
  end

  def coerce_context(key, value)
    attrs = value.respond_to?(:to_h) ? value.to_h.transform_keys(&:to_sym).slice(*Context.members) : {}
    key_account, key_underlying = key.is_a?(Array) ? key : [ nil, key ]
    attrs[:account_id] = key_account if attrs[:account_id].nil?
    attrs[:underlying] = key_underlying if attrs[:underlying].nil?
    attrs[:underlying] = attrs[:underlying].to_s.strip.upcase.presence
    Context.new(**attrs)
  end

  def blank_context(underlying)
    Context.new(underlying: underlying)
  end

  def integer(value)
    Options::Values.decimal(value)&.floor
  end

  def date(value)
    value.respond_to?(:to_date) ? value.to_date : nil
  rescue ArgumentError, Date::Error
    nil
  end
  private_class_method :rank_key, :evaluate, :model_row, :normalize, :valid_row?, :holdings_reasons, :clamped_cash,
                       :build_idea, :annualized_yield, :earnings_flags, :in_window?, :exclusion, :index_contexts,
                       :coerce_context, :blank_context, :integer, :date
end
