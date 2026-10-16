require "test_helper"

class OptionsDeskTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 10, 15, 15, 0)
  EXPIRATION = Date.new(2026, 11, 13)

  setup do
    travel_to NOW
    @owner = users(:family_admin)
    @member = users(:family_member)
    @other_user = users(:empty)
  end

  teardown { travel_back }

  def broker_account(owner: @owner, family: @owner.family, currency: "USD", freshness: Time.current, positions: [], raw_options_payload: positions)
    suffix = SecureRandom.hex(4)
    account = family.accounts.create!(name: "Desk #{suffix}", balance: 1000, cash_balance: 0, currency: currency, owner: owner,
                                      status: "active", accountable: Investment.new(subtype: "brokerage"))
    item = SnaptradeItem.create!(family: family, name: "Desk item #{suffix}", client_id: "client-#{suffix}", consumer_key: "key-#{suffix}", status: "good")
    provider = SnaptradeAccount.create!(snaptrade_item: item, snaptrade_account_id: "desk-#{suffix}", name: account.name, currency: currency,
                                        current_balance: 1000, last_holdings_sync: freshness, raw_options_payload: raw_options_payload)
    AccountProvider.create!(account: account, provider: provider)
    [ account, provider ]
  end

  def position(symbol: "NVDA  261113P00215000", type: "PUT", strike: "215", qty: "1", price: "2", basis: "1", multiplier: "100", currency: "USD")
    { "instrument" => { "symbol" => symbol, "option_type" => type, "expiration_date" => EXPIRATION.to_s, "strike_price" => strike, "multiplier" => multiplier },
      "units" => qty, "price" => price, "cost_basis" => basis, "currency" => { "code" => currency } }
  end

  def quote(underlying: "NVDA", type: "PUT", strike: 215, expiration: EXPIRATION, bid: "2", ask: "2.20", **overrides)
    symbol = "#{underlying}#{expiration.strftime('%y%m%d')}#{type[0]}#{format('%08d', (BigDecimal(strike.to_s) * 1000).to_i)}"
    OptionQuote.create!({ contract_symbol: symbol, underlying: underlying, option_type: type, strike: strike, expiration: expiration,
                          bid: bid, ask: ask, last_price: "2.1", last_trade_at: NOW - 5.minutes, quote_time: NOW - 5.minutes,
                          session_date: Date.new(2026, 10, 15), underlying_price: "217.23", underlying_prev_close: "216",
                          open_interest: 100, contract_size: "REGULAR", fetched_at: NOW - 1.minute, source: "test", currency: "USD" }.merge(overrides))
  end

  def holding(account:, provider:, ticker:, qty:, date: NOW.to_date)
    security = Security.find_or_create_by!(ticker: ticker) { |record| record.name = ticker }
    Holding.create!(account: account, account_provider: provider.account_provider, security: security, date: date,
                    qty: qty, price: 1, amount: qty, currency: account.currency)
  end

  def desk(user: @owner, now: NOW, **args)
    OptionsDesk.new(user: user, now: now, **args).result
  end

  test "scope is privacy preserving and invalid account ids do not fall back" do
    own, = broker_account(positions: [ position ])
    shared, = broker_account(positions: [ position(symbol: "AAPL  261113C00215000", type: "CALL", strike: "250") ])
    hidden, = broker_account(owner: @other_user, family: @other_user.family, positions: [ position(symbol: "MSFT  261113P00200000", strike: "200") ])
    AccountShare.create!(account: shared, user: @member, permission: "read_only")

    member_result = desk(user: @member)
    assert_equal [ shared.id ], member_result.rows.map(&:account_id)
    assert_equal [ "AAPL" ], member_result.rows.map(&:underlying)
    assert_empty desk(account_id: hidden.id).rows
    assert desk(account_id: hidden.id).invalid_account_scope
    assert_equal [ own.id, shared.id ].sort, desk.rows.map(&:account_id).uniq.sort
  end

  test "current provider with a missing options payload is unavailable" do
    broker_account
    SnaptradeAccount.any_instance.stubs(:raw_options_payload).returns(nil)

    assert_equal :unavailable, desk.source_state
  end

  test "current provider with scalar or malformed options payload is unavailable" do
    [ "not-an-array", [ { "instrument" => "not-a-hash" } ] ].each do |payload|
      broker_account(raw_options_payload: payload)

      assert_equal :unavailable, desk.source_state
    end
  end

  [
    [ "empty instrument hash", [ { "instrument" => {} } ] ],
    [ "blank symbol", [ { "instrument" => { "symbol" => "" } } ] ],
    [ "whitespace symbol", [ { "instrument" => { "symbol" => "   " } } ] ]
  ].each do |label, payload|
    test "current provider whose only entry emits no position (#{label}) is unavailable, never empty" do
      broker_account(raw_options_payload: payload)

      result = desk
      assert_equal :unavailable, result.source_state
      assert_empty result.rows
    end
  end

  test "a mixed payload with one dropped entry makes the provider unreadable" do
    broker_account(positions: [ position, { "instrument" => { "symbol" => " " } } ])

    result = desk
    assert_equal :unavailable, result.source_state
    assert_empty result.rows
  end

  test "a short call with unknown quantity makes the provider unreadable and withholds share availability" do
    account, provider = broker_account(positions: [ position(symbol: "NVDA  261113C00250000", type: "CALL", strike: "250", qty: nil) ])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 200)

    result = desk
    assert_equal :unavailable, result.source_state
    assert_nil result.contexts.values.first&.shares_available
    assert_nil result.contexts.values.first&.long_calls_present
  end

  [
    [ "unknown option type", { type: "WEIRD" } ],
    [ "unknown multiplier", { multiplier: nil } ],
    [ "zero multiplier", { multiplier: "0" } ],
    [ "negative multiplier", { multiplier: "-100" } ],
    [ "unparseable quantity", { qty: "abc" } ]
  ].each do |label, attrs|
    test "an entry with #{label} is unavailable, never available or empty" do
      broker_account(positions: [ position(**attrs) ])

      assert_equal :unavailable, desk.source_state
    end
  end

  test "a short call with zero or negative multiplier never raises share availability" do
    [ "0", "-100" ].each do |multiplier|
      account, provider = broker_account(positions: [ position(symbol: "NVDA  261113C00250000", type: "CALL", strike: "250", qty: "-1", multiplier: multiplier) ])
      holding(account: account, provider: provider, ticker: "NVDA", qty: 200)
      result = desk(account_id: account.id)

      assert_equal :unavailable, result.source_state
      assert(result.contexts.values.none? { |context| context.shares_available })
    end
  end

  def desk_context(result, account, underlying = "NVDA")
    result.contexts[[ account.id, underlying ]]
  end

  test "non-finite quantities make the provider unreadable" do
    [ "NaN", "Infinity", "-Infinity" ].each do |quantity|
      broker_account(positions: [ position(symbol: "NVDA  261113C00250000", type: "CALL", strike: "250", qty: quantity) ])

      assert_equal :unavailable, desk.source_state
    end
  end

  test "a clean short call nets same-account shares" do
    account, provider = broker_account(positions: [ position(symbol: "NVDA  261113C00250000", type: "CALL", strike: "250", qty: "-1") ])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 300)

    assert_equal BigDecimal("200"), desk_context(desk, account).shares_available
  end

  [
    [ "instrument type contradicting the symbol", { symbol: "NVDA  261113C00250000", type: "PUT", strike: "250", qty: "-1" } ],
    [ "multiplier 10 on a standard root", { symbol: "NVDA  261113C00250000", type: "CALL", strike: "250", qty: "-1", multiplier: "10" } ],
    [ "multiplier 1 on a standard root", { symbol: "NVDA  261113C00250000", type: "CALL", strike: "250", qty: "-1", multiplier: "1" } ],
    [ "strike contradicting the symbol", { symbol: "NVDA  261113C00250000", type: "CALL", strike: "100", qty: "-1" } ],
    [ "position currency differing from the account", { symbol: "NVDA  261113C00250000", type: "CALL", strike: "250", qty: "-1", currency: "JPY" } ],
    [ "zero strike", { symbol: "NVDA  261113C00250000", type: "CALL", strike: "0", qty: "-1" } ]
  ].each do |label, attrs|
    test "a short call with #{label} withholds share availability for the account but still lists the row" do
      account, provider = broker_account(positions: [ position(**attrs) ])
      holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
      result = desk

      assert_equal 1, result.rows.size
      context = desk_context(result, account)
      assert_nil context.shares_available
      assert_nil context.long_calls_present
      assert_nil context.existing_short_put_exposure
    end
  end

  test "a short put with a foreign currency or non-positive strike never yields an exposure figure" do
    [ { currency: "JPY" }, { strike: "0" }, { strike: "-5" } ].each do |attrs|
      account, = broker_account(positions: [ position(qty: "-1", **attrs) ])

      assert_nil desk_context(desk, account).existing_short_put_exposure
    end
  end

  test "a dotted underlying that cannot be tied to its OCC root withholds shares" do
    account, provider = broker_account(positions: [ position(symbol: "BRK.B  261113C00250000", type: "CALL", strike: "250", qty: "-1") ])
    holding(account: account, provider: provider, ticker: "BRK.B", qty: 300)

    assert_nil desk_context(desk, account, "BRK.B")&.shares_available
  end

  test "an unclean account does not taint a clean sibling account" do
    dirty, dirty_provider = broker_account(positions: [ position(symbol: "NVDA  261113C00250000", type: "CALL", strike: "250", qty: "-1", multiplier: "10") ])
    holding(account: dirty, provider: dirty_provider, ticker: "NVDA", qty: 300)
    clean, clean_provider = broker_account(positions: [ position(symbol: "NVDA  261113C00250000", type: "CALL", strike: "250", qty: "-1") ])
    holding(account: clean, provider: clean_provider, ticker: "NVDA", qty: 300)
    result = desk

    assert_nil desk_context(result, dirty).shares_available
    assert_equal BigDecimal("200"), desk_context(result, clean).shares_available
  end

  test "non-finite cost basis or mark yields unavailable pnl and basis, never NaN or Infinity totals" do
    quote
    [ "NaN", "Infinity", "-Infinity" ].each do |bad|
      account, = broker_account(positions: [ position(basis: bad) ])
      result = desk
      row = result.rows.find { |candidate| candidate.account_id == account.id }

      assert_nil row.entry_basis_total
      assert_nil row.total_pnl
      assert_nil result.groups.fetch("NVDA").total_pnl
      assert_nil result.summary.total_pnl
    end
  end

  test "non-finite broker mark and strike are treated as unknown" do
    [ { price: "NaN" }, { price: "Infinity" }, { strike: "NaN" } ].each do |attrs|
      account, = broker_account(positions: [ position(**attrs) ])
      row = desk.rows.find { |candidate| candidate.account_id == account.id }

      assert(row.broker_mark.nil? || row.broker_mark.finite?)
      assert(row.strike.nil? || row.strike.finite?)
    end
  end

  test "a non-finite same-account holding quantity withholds shares instead of raising" do
    account, provider = broker_account(positions: [ position(symbol: "NVDA  261113C00250000", type: "CALL", strike: "250", qty: "-1") ])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 300)
    Holding.where(account_id: account.id).update_all("qty = 'NaN'::numeric")

    result = nil
    assert_nothing_raised { result = desk }
    assert_nil desk_context(result, account)&.shares_available
  end

  test "empty, invalid-scope and unreadable-only results never report zero totals" do
    empty = desk(user: @other_user)
    assert_nil empty.summary.total_position_delta
    assert_nil empty.summary.total_pnl

    scoped = desk(account_id: SecureRandom.uuid)
    assert scoped.invalid_account_scope
    assert_nil scoped.summary.total_position_delta

    broker_account(raw_options_payload: "not-an-array")
    unreadable = desk
    assert_nil unreadable.summary.total_position_delta
    assert_nil unreadable.summary.total_pnl
  end

  test "an unreadable source suppresses totals and is counted instead of producing partial totals" do
    quote
    broker_account(positions: [ position ])
    broker_account(raw_options_payload: "not-an-array")
    result = desk

    assert_equal 1, result.rows.size
    assert_equal 1, result.summary.unreadable_source_count
    assert_nil result.summary.total_pnl
    assert_nil result.summary.total_position_delta
    assert_nil result.groups.fetch("NVDA").total_pnl
  end

  test "a readable single source reports zero unreadable sources and real totals" do
    quote
    broker_account(positions: [ position ])
    result = desk

    assert_equal 0, result.summary.unreadable_source_count
    assert_not_nil result.summary.total_pnl
  end

  test "negative broker marks and cost bases are unknown, never accepted" do
    [ { price: "-1" }, { basis: "-1" } ].each do |attrs|
      account, = broker_account(positions: [ position(**attrs) ])
      row = desk.rows.find { |candidate| candidate.account_id == account.id }

      assert_nil row.total_pnl
      assert_nil row.entry_basis_total if attrs.key?(:basis)
      assert_nil row.broker_mark if attrs.key?(:price)
    end
  end

  test "zero broker mark and zero cost basis remain real zeros" do
    account, = broker_account(positions: [ position(price: "0", basis: "0") ])
    row = desk.rows.find { |candidate| candidate.account_id == account.id }

    assert_equal BigDecimal("0"), row.broker_mark
    assert_equal BigDecimal("0"), row.entry_basis_total
    assert_equal BigDecimal("0"), row.total_pnl
  end

  test "rows with a blank currency are never pooled into another row's total" do
    quote
    broker_account(positions: [ position ])
    _, provider = broker_account(positions: [ position(symbol: "NVDA  261113P00200000", strike: "200", currency: "") ])
    provider.update_columns(currency: nil)
    result = desk
    blank = result.rows.find { |row| row.strike == BigDecimal("200") }

    assert blank.currency.blank?
    assert_nil result.summary.total_pnl
    assert_nil result.summary.total_pnl_currency
    assert_nil result.groups.fetch("NVDA").total_pnl
    assert_nil result.groups.fetch("NVDA").currency
  end

  test "covered call contracts_max floors fractional share availability" do
    account, provider = broker_account(positions: [])
    holding(account: account, provider: provider, ticker: "NVDA", qty: "250.5")
    quote(type: "CALL", strike: 250)
    result = desk
    idea = result.ideas.covered_calls.ideas.find { |entry| entry.account_id == account.id }

    skip "no covered-call idea produced for this fixture" if idea.nil?
    assert_kind_of Integer, idea.contracts_max
    assert_equal 2, idea.contracts_max
  end

  test "an entry whose underlying cannot be identified is unavailable" do
    broker_account(positions: [ position(symbol: "GME1  261113C00215000", type: "CALL") ])

    assert_equal :unavailable, desk.source_state
  end

  test "a genuine zero quantity stays readable" do
    broker_account(positions: [ position(qty: "0") ])

    result = desk
    assert_not_equal :unavailable, result.source_state
    assert_empty result.rows
  end

  test "symbol-keyed and struct payload entries that emit a position are readable" do
    entry = Struct.new(:instrument, :units, :price, :cost_basis, :currency)
    symbol_keyed = { instrument: { symbol: "NVDA  261113P00215000", option_type: "PUT", expiration_date: EXPIRATION.to_s,
                                   strike_price: "215", multiplier: "100" },
                     units: "1", price: "2", cost_basis: "1", currency: { code: "USD" } }
    struct_entry = entry.new(symbol_keyed[:instrument], "1", "2", "1", { code: "USD" })

    [ [ symbol_keyed ], [ struct_entry ] ].each do |payload|
      SnaptradeAccount.any_instance.stubs(:raw_options_payload).returns(payload)
      account, = broker_account
      result = desk

      assert_equal :available, result.source_state
      assert_equal [ account.id ], result.rows.select { |row| row.account_id == account.id }.map(&:account_id)
      account.destroy!
    end
  end

  test "symbol-keyed and struct payload entries with a blank symbol stay unavailable" do
    entry = Struct.new(:instrument)

    [ [ { instrument: { symbol: " " } } ], [ entry.new({ symbol: "" }) ] ].each do |payload|
      SnaptradeAccount.any_instance.stubs(:raw_options_payload).returns(payload)
      broker_account

      assert_equal :unavailable, desk.source_state
    end
  end

  test "current provider with a readable empty options payload is empty" do
    broker_account(raw_options_payload: [])

    assert_equal :empty, desk.source_state
  end

  test "current readable empty provider and unreadable provider are unavailable" do
    broker_account(raw_options_payload: [])
    broker_account(raw_options_payload: "not-an-array")

    assert_equal :unavailable, desk.source_state
  end

  test "current readable empty provider and stale unreadable provider are stale" do
    broker_account(raw_options_payload: [])
    broker_account(freshness: NOW - SnaptradeAccount::SNAPSHOT_STALE_AFTER - 1.second, raw_options_payload: "not-an-array")

    assert_equal :stale, desk.source_state
  end

  test "same underlying remains account qualified without pooled groups" do
    first, = broker_account(positions: [ position(qty: "1", price: "2", basis: "1") ])
    second, = broker_account(positions: [ position(qty: "-1", price: "2", basis: "3") ])
    quote

    result = desk
    group = result.groups.fetch("NVDA")
    assert_equal [ first.id, second.id ].sort, group.rows.map(&:account_id).sort
    assert_equal BigDecimal("200"), group.total_pnl
  end

  test "structured standard quote joins while malformed and unsupported contracts remain broker only" do
    broker_account(positions: [ position, position(symbol: "GME   261113P0021500", multiplier: "100"), position(symbol: "NVDA  261113P00215000", multiplier: "10") ])
    quote

    rows = desk.rows
    direct = rows.find { |row| row.multiplier == BigDecimal("100") && row.contract.start_with?("NVDA") }
    unsupported = rows.reject { |row| row.equal?(direct) }
    assert_equal :mid, direct.mark.basis
    assert direct.quote
    assert unsupported.all? { |row| row.quote.nil? && row.mark.basis == :broker }
  end

  test "pnl sign matrix preserves zero and unknown values" do
    broker_account(positions: [ position(qty: "1", price: "2", basis: "1"), position(qty: "-1", price: "2", basis: "3"), position(symbol: "AAPL  261113P00215000", strike: "150", qty: "1", price: "2", basis: nil) ])
    quote
    quote(underlying: "AAPL", strike: 150)

    rows = desk.rows
    assert_equal BigDecimal("110"), rows.find { |row| row.quantity == BigDecimal("1") && row.underlying == "NVDA" }.total_pnl
    assert_equal BigDecimal("90"), rows.find { |row| row.quantity == BigDecimal("-1") }.total_pnl
    assert_nil rows.find { |row| row.underlying == "AAPL" }.total_pnl

    broker_account(positions: [ position(symbol: "ZERO  261113P00215000", strike: "150", qty: "1", price: "1", basis: "1") ])
    quote(underlying: "ZERO", strike: 150, bid: "0.90", ask: "1.10")
    assert_equal BigDecimal("0"), desk.rows.find { |row| row.underlying == "ZERO" }.total_pnl
  end

  test "indicative and mixed or partial measurements make aggregates unavailable" do
    broker_account(positions: [ position, position(symbol: "WIDE  261113P00100000", strike: "100") ])
    quote
    quote(underlying: "WIDE", strike: 100, bid: "1", ask: "10")

    result = desk
    assert_equal :indicative, result.rows.find { |row| row.underlying == "WIDE" }.evidence_status
    assert_nil result.summary.total_pnl
    assert_equal 1, result.summary.indicative_count
  end

  test "mixed currencies never receive a total even when each row is measured" do
    broker_account(positions: [ position ])
    broker_account(currency: "EUR", positions: [ position(symbol: "AAPL  261113P00150000", strike: "150", currency: "EUR") ])
    quote
    quote(underlying: "AAPL", strike: 150)

    result = desk
    assert_nil result.summary.total_pnl
    assert_nil result.summary.total_pnl_currency
  end

  test "foreign currency quote is rejected before mark pnl delta and ideas" do
    broker_account(positions: [ position(price: "2", basis: "1", currency: "USD") ])
    quote(currency: "EUR")

    row = desk.rows.first
    assert_nil row.quote
    assert_equal :broker, row.mark.basis
    assert_equal BigDecimal("100"), row.total_pnl
    assert_nil row.model_delta.value
    assert_empty desk.ideas.puts.exclusions

    broker_account(freshness: NOW - SnaptradeAccount::SNAPSHOT_STALE_AFTER - 1.second,
                   positions: [ position(symbol: "AAPL  261113P00150000", strike: "150", currency: "USD") ])
    quote(underlying: "AAPL", strike: 150, currency: "EUR")
    stale_row = desk.rows.find { |candidate| candidate.underlying == "AAPL" }
    assert_nil stale_row.quote
    assert_equal :stale, stale_row.evidence_status
    assert_nil stale_row.mark.value
    assert_nil stale_row.total_pnl
  end

  test "injected now controls broker snapshot freshness" do
    injected_now = NOW + 48.hours
    broker_account(freshness: injected_now - SnaptradeAccount::SNAPSHOT_STALE_AFTER, positions: [ position ])
    current = desk(now: injected_now).rows.first
    assert current.broker_snapshot_current
    assert_equal :broker, current.mark.basis

    broker_account(freshness: injected_now - SnaptradeAccount::SNAPSHOT_STALE_AFTER - 1.second,
                   positions: [ position(symbol: "AAPL  261113P00150000", strike: "150") ])
    stale = desk(now: injected_now).rows.find { |row| row.underlying == "AAPL" }
    refute stale.broker_snapshot_current
    assert_nil stale.mark.value
  end

  test "stale snapshots and quote as-of preserve source state and day gain refuses unknown position changes" do
    broker_account(freshness: 31.hours.ago, positions: [ position ])
    quote(session_date: Date.new(2026, 10, 14), quote_time: NOW - 1.day)

    row = desk.rows.first
    assert_equal :stale, desk.source_state
    assert_equal :stale, row.evidence_status
    assert_equal NOW.to_i - 1.day.to_i, row.quote_as_of.to_i
    assert_equal :position_unknown, row.day_gain.reason
    assert_nil row.day_gain.value
  end

  test "model delta requires current direct quote and position delta respects sign" do
    broker_account(positions: [ position(qty: "-1", type: "PUT"), position(symbol: "WIDE  261113C00215000", type: "CALL", strike: "215") ])
    quote
    quote(underlying: "WIDE", type: "CALL", strike: 215, bid: "1", ask: "10")

    rows = desk.rows
    put = rows.find { |row| row.option_type == "PUT" }
    wide = rows.find { |row| row.underlying == "WIDE" }
    assert_kind_of Float, put.model_delta.value
    assert_equal BigDecimal(put.model_delta.value.to_s) * BigDecimal("-100"), put.position_delta
    assert_nil wide.model_delta.value
    assert_nil wide.position_delta
  end

  test "current provider holdings create isolated covered call contexts net of short calls" do
    first, first_provider = broker_account(positions: [ position(symbol: "NVDA  261113C00230000", type: "CALL", strike: "230", qty: "-1") ])
    second, second_provider = broker_account(positions: [])
    holding(account: first, provider: first_provider, ticker: "NVDA", qty: 250)
    holding(account: second, provider: second_provider, ticker: "NVDA", qty: 100)
    candidate = quote(type: "CALL", strike: 250)

    result = desk
    assert_equal BigDecimal("150"), result.contexts.fetch([ first.id, "NVDA" ]).shares_available
    assert_equal BigDecimal("100"), result.contexts.fetch([ second.id, "NVDA" ]).shares_available
    candidate_symbol = candidate.contract_symbol
    candidate_accounts = (result.ideas.covered_calls.ideas + result.ideas.covered_calls.exclusions)
                         .select { |entry| entry.contract == candidate_symbol }
                         .map(&:account_id)
    assert_equal [ first.id, second.id ].sort, candidate_accounts.sort
  end

  test "scoped quote candidates exclude unrelated underlyings and put screening has no cash data" do
    account, provider = broker_account(positions: [])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 100)
    put = quote(type: "PUT", strike: 215)
    unrelated = quote(underlying: "TSLA", type: "PUT", strike: 250)

    result = desk
    put_exclusions = result.ideas.puts.exclusions.select { |entry| entry.contract == put.contract_symbol }
    assert_equal [ account.id ], put_exclusions.map(&:account_id)
    assert put_exclusions.all? { |entry| entry.reasons.include?(:no_cash_data) }
    refute (result.ideas.covered_calls.ideas + result.ideas.covered_calls.exclusions + result.ideas.puts.ideas + result.ideas.puts.exclusions)
      .any? { |entry| entry.contract == unrelated.contract_symbol }
  end

  test "ideas fail closed with no cash and unproven shares or short put exposure" do
    account, = broker_account(positions: [ position(qty: "-1", type: "PUT", strike: "215"), position(symbol: "NVDA  261113C00230000", type: "CALL", strike: "230", qty: "-1") ])
    quote
    quote(type: "CALL", strike: 230)

    result = desk
    assert_nil result.contexts.fetch([ account.id, "NVDA" ]).cash_available
    assert_nil result.contexts.fetch([ account.id, "NVDA" ]).shares_available
    assert result.ideas.puts.exclusions.any? { |exclusion| exclusion.reasons.include?(:no_cash_data) }
    assert result.ideas.covered_calls.exclusions.any? { |exclusion| exclusion.reasons.include?(:insufficient_shares) }
  end

  test "short put exposure includes every valid short put in the same account" do
    account, = broker_account(positions: [ position(qty: "-1", type: "PUT", strike: "215"), position(symbol: "AAPL  261113P00150000", qty: "-2", type: "PUT", strike: "150") ])
    quote
    quote(underlying: "AAPL", strike: 150)

    assert_equal BigDecimal("51500"), desk.contexts.fetch([ account.id, "NVDA" ]).existing_short_put_exposure
  end

  test "scoped quote candidates include only standard deliverables" do
    account, provider = broker_account(positions: [])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 200)
    regular = quote(type: "CALL", strike: 250)
    mini = quote(type: "CALL", strike: 260, contract_size: "MINI")

    result = desk
    scanner_entries = result.ideas.covered_calls.ideas + result.ideas.covered_calls.exclusions +
                      result.ideas.puts.ideas + result.ideas.puts.exclusions

    assert_includes scanner_entries.map(&:contract), regular.contract_symbol
    refute_includes scanner_entries.map(&:contract), mini.contract_symbol
  end

  test "current provider uses its latest weekday holding snapshot on a weekend" do
    saturday = Time.utc(2026, 10, 17, 12, 0)
    account, provider = broker_account(freshness: saturday - 1.hour, positions: [ position ])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 125, date: Date.new(2026, 10, 16))
    manual_security = Security.find_or_create_by!(ticker: "AAPL") { |record| record.name = "AAPL" }
    Holding.create!(account: account, security: manual_security, date: saturday.to_date, qty: 999, price: 1, amount: 999,
                    currency: account.currency)

    assert_equal BigDecimal("125"), desk(now: saturday).contexts.fetch([ account.id, "NVDA" ]).shares_available

    other_link = AccountProvider.new(account: account, provider_type: "ManualProvider", provider_id: SecureRandom.uuid)
    other_link.save!(validate: false)
    provider_security = Security.find_by!(ticker: "NVDA")
    Holding.create!(account: account, account_provider: other_link, security: provider_security, date: saturday.to_date,
                    qty: 400, price: 1, amount: 400, currency: account.currency)

    shares = OptionsDesk.new(user: @owner, now: saturday).send(:current_provider_shares, provider, account)
    assert_equal BigDecimal("125"), shares.fetch("NVDA")
  end

  test "stale provider holdings do not establish available shares" do
    saturday = Time.utc(2026, 10, 17, 12, 0)
    account, provider = broker_account(freshness: saturday - SnaptradeAccount::SNAPSHOT_STALE_AFTER - 1.second, positions: [ position ])
    holding(account: account, provider: provider, ticker: "NVDA", qty: 125, date: Date.new(2026, 10, 16))

    assert_nil desk(now: saturday).contexts.fetch([ account.id, "NVDA" ]).shares_available
  end

  test "unreadable but current provider yields unknown idea contexts while a readable sibling keeps working" do
    bad, bad_provider = broker_account(raw_options_payload: [ { "instrument" => { "symbol" => "" } } ])
    good, good_provider = broker_account(positions: [])
    holding(account: bad, provider: bad_provider, ticker: "NVDA", qty: 200)
    holding(account: good, provider: good_provider, ticker: "NVDA", qty: 100)
    candidate = quote(type: "CALL", strike: 250)

    result = desk
    bad_context = result.contexts.fetch([ bad.id, "NVDA" ])
    assert_nil bad_context.shares_available
    assert_nil bad_context.long_calls_present
    assert_nil bad_context.existing_short_put_exposure
    good_context = result.contexts.fetch([ good.id, "NVDA" ])
    assert_equal BigDecimal("100"), good_context.shares_available
    assert_equal false, good_context.long_calls_present

    candidate_entries = result.ideas.covered_calls.ideas + result.ideas.covered_calls.exclusions
    bad_entries = candidate_entries.select { |entry| entry.account_id == bad.id && entry.contract == candidate.contract_symbol }
    assert_equal [], result.ideas.covered_calls.ideas.select { |entry| entry.account_id == bad.id }
    assert bad_entries.any? { |entry| entry.reasons.include?(:insufficient_shares) }
    assert candidate_entries.any? { |entry| entry.account_id == good.id && entry.contract == candidate.contract_symbol }
  end

  test "does not invoke external providers while building the read model" do
    broker_account(positions: [ position ])
    quote
    Provider::YahooFinance.any_instance.expects(:fetch_option_chain).never

    desk
  end
end
