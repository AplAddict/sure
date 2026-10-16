# Refreshes cached option quotes. Runs from a scheduled job, never on page load.
#
# Quotes are public market data, so the universe spans every linked broker
# account regardless of family; it is read only from persisted broker snapshots
# and held positions, never from a user session.
#
# Two phases with separate request budgets:
#   1. held (HELD_BUDGET): every (underlying, expiration) a broker account
#      holds, stalest first, always before anything else.
#   2. ideas (IDEA_BUDGET): chains for sell-put / covered-call scans, rotated
#      stalest first so a capped run moves through the whole idea set.
# The first rate limit ends the run and sets a shared cooldown; a failed fetch
# never modifies stored rows, and a missing figure never erases a stored one.
class OptionQuote::Refresher
  HELD_BUDGET = 40
  IDEA_BUDGET = 20
  MAX_IDEA_UNDERLYINGS = 40
  PAUSE_BETWEEN_REQUESTS = 1.5
  FAILURE_BACKOFF = 1.hour
  COOLDOWN_KEY = "yahoo:cooldown"
  COOLDOWN = 15.minutes
  PRUNE_AFTER_DAYS = 7
  IDEA_EXPIRATIONS = 2
  IDEA_DTE_WINDOW = (21..45)
  IDEA_SHARES_MIN = 100
  STRIKE_BAND = BigDecimal("0.3")
  MARKET_ZONE = "America/New_York"
  # Yahoo spells class shares differently (BRK-B), so dotted tickers are skipped.
  UNDERLYING = /\A[A-Z]{1,5}\z/

  # Resolved at call time: the Options calc namespace may not be loaded yet.
  DEFAULT_SESSION_MARK_FN = ->(attrs) { Options::Mark.session_mark(**attrs.slice(:bid, :ask, :last_price, :last_trade_at, :session_date)) }

  # Fields a fetch writes. Within a session a nil never replaces a stored value.
  QUOTE_FIELDS = %i[
    last_price bid ask change percent_change implied_volatility open_interest volume last_trade_at
    underlying_price underlying_prev_close quote_time session_date contract_size currency
  ].freeze

  Universe = Data.define(:broker_pairs, :held_symbols, :idea_underlyings)
  Result = Data.define(:refreshed, :failed, :skipped_for_rate_limit, :requests, :backed_off, :pruned)

  # The calendar date in New York: the only "today" this feature uses.
  def self.market_date(now = Time.current) = now.in_time_zone(MARKET_ZONE).to_date

  # What would be fetched, from persisted data only (no provider calls):
  # broker_pairs      - [underlying, expiration] of every open contract, deduped
  # held_symbols      - normalized contract symbols actually held
  # idea_underlyings  - tickers to scan for sell-put / covered-call chains
  def self.universe(today: market_date)
    pairs = Set.new
    symbols = Set.new

    SnaptradeAccount.linked_to(Account.visible.select(:id)).each do |provider_account|
      provider_account.option_positions_snapshot.each do |position|
        next if position.quantity.nil? || position.quantity.zero?
        next if position.expiration.nil? || position.expiration < today
        next unless position.underlying.to_s.match?(UNDERLYING)

        pairs << [ position.underlying, position.expiration ]
        symbols << OptionQuote.normalize_symbol(position.contract)
      end
    end

    Universe.new(broker_pairs: pairs.to_a, held_symbols: symbols, idea_underlyings: idea_underlyings)
  end

  # 100+ shares in a single account (a coverable lot) come first, then every
  # other held security, so the cap keeps the likeliest ideas.
  def self.idea_underlyings
    lots = Holding.where("date >= ?", 10.days.ago.to_date).where("qty >= ?", IDEA_SHARES_MIN).select(:security_id)
    lot_tickers = Security.where(id: lots, offline: false, kind: "standard").pluck(:ticker).select { |ticker| ticker.to_s.match?(UNDERLYING) }.sort
    held_tickers = Security::FundamentalsRefresher.held_securities.map(&:ticker).select { |ticker| ticker.to_s.match?(UNDERLYING) }.sort

    (lot_tickers + held_tickers).uniq.first(MAX_IDEA_UNDERLYINGS)
  end

  # session_mark_fn: ->(old_row_attrs) { BigDecimal|nil }, called once when a
  # row moves to a new session, to freeze the finished session's mark.
  def initialize(provider: Provider::YahooFinance.new, pause: PAUSE_BETWEEN_REQUESTS, session_mark_fn: DEFAULT_SESSION_MARK_FN)
    @provider = provider
    @pause = pause
    @session_mark_fn = session_mark_fn
  end

  def refresh_all(held_budget: HELD_BUDGET, idea_budget: IDEA_BUDGET, today: nil)
    return cooldown_result if Rails.cache.exist?(COOLDOWN_KEY)

    @today = today || self.class.market_date
    @budgets = { held: held_budget, idea: idea_budget }
    @spent = { held: 0, idea: 0 }
    @requests = 0
    @refreshed = 0
    @failed = 0
    @backed_off = 0
    @rate_limited = false
    @fetched = Set.new
    @expirations = {}

    universe = self.class.universe(today: @today)
    @held_symbols = universe.held_symbols

    refresh_held(universe.broker_pairs)
    refresh_ideas(universe.idea_underlyings) unless @rate_limited

    Result.new(refreshed: @refreshed, failed: @failed, skipped_for_rate_limit: @rate_limited,
               requests: @requests, backed_off: @backed_off, pruned: prune_expired)
  end

  private

    def cooldown_result
      Result.new(refreshed: 0, failed: 0, skipped_for_rate_limit: true, requests: 0, backed_off: 0, pruned: 0)
    end

    def budget_left?(phase) = !@rate_limited && @spent[phase] < @budgets[phase]

    def refresh_held(pairs)
      pairs.sort_by { |symbol, expiration| [ last_fetched_at(symbol, expiration), symbol, expiration ] }.each do |symbol, expiration|
        break unless budget_left?(:held)

        fetch_and_store(symbol, expiration, :held)
      end
    end

    # Stalest first across the (already capped) idea set, so successive runs
    # cover every underlying. Underlyings never fetched sort first.
    def refresh_ideas(underlyings)
      underlyings.each_with_index.sort_by { |symbol, index| [ underlying_fetched_at(symbol), index ] }.map(&:first).each do |symbol|
        break unless budget_left?(:idea)

        expirations = expirations_for(symbol) || discover_expirations(symbol)
        next if expirations.blank?

        nearest_to_idea_window(expirations).each do |expiration|
          break unless budget_left?(:idea)

          fetch_and_store(symbol, expiration, :idea) unless @fetched.include?([ symbol, expiration ])
        end
      end
    end

    # The nearest-expiry chain doubles as the expiration list. Its rows are kept
    # too when that expiry is one we want anyway.
    def discover_expirations(symbol)
      data = request(symbol, nil, :idea)
      return nil unless data

      remember_expirations(symbol, data[:expirations])
      expirations = data[:expirations]
      nearest = expirations.min
      @fetched << [ symbol, nearest ] if nearest && nearest_to_idea_window(expirations).include?(nearest) && store(symbol, nearest, data)
      expirations
    end

    # The expirations closest to the 21-45 day window; ties go to the earlier date.
    def nearest_to_idea_window(expirations)
      expirations.select { |date| date >= @today }
                 .sort_by { |date| [ distance_from_window((date - @today).to_i), date ] }
                 .first(IDEA_EXPIRATIONS)
    end

    def distance_from_window(days)
      return 0 if IDEA_DTE_WINDOW.cover?(days)

      [ (days - IDEA_DTE_WINDOW.begin).abs, (days - IDEA_DTE_WINDOW.end).abs ].min
    end

    def fetch_and_store(symbol, expiration, phase)
      data = request(symbol, expiration, phase)
      return unless data

      remember_expirations(symbol, data[:expirations])
      if store(symbol, expiration, data)
        @fetched << [ symbol, expiration ]
        @refreshed += 1
      else
        fail!(symbol, expiration)
      end
    end

    # One provider call, counted against its phase's budget. Returns the chain
    # or nil; a failure never touches stored rows.
    def request(symbol, expiration, phase)
      if backed_off?(symbol, expiration)
        @backed_off += 1
        return nil
      end

      sleep(@pause) if @pause.positive? && @requests.positive?
      @requests += 1
      @spent[phase] += 1
      response = @provider.fetch_option_chain(symbol: symbol, expiration: expiration)

      return response.data if response.success? && response.data.present? && valid_quote_time?(response.data[:quote_time])

      if response.success? && response.data.present?
        fail!(symbol, expiration)
      elsif rate_limited?(response.error)
        rate_limit!
      else
        fail!(symbol, expiration)
      end
      nil
    rescue Provider::YahooFinance::RateLimitError
      rate_limit!
      nil
    rescue StandardError => e
      Rails.logger.warn("[OptionQuotes] #{symbol} #{expiration || 'nearest'} failed: #{e.class}: #{e.message.to_s.truncate(120)}")
      fail!(symbol, expiration)
      nil
    end

    def valid_quote_time?(quote_time)
      quote_time.respond_to?(:utc) && quote_time.respond_to?(:in_time_zone)
    end

    def rate_limited?(error)
      error.is_a?(Provider::YahooFinance::RateLimitError) || error&.message.to_s.match?(/429|too many|rate limit/i)
    end

    def rate_limit!
      @rate_limited = true
      Rails.cache.write(COOLDOWN_KEY, true, expires_in: COOLDOWN)
    end

    def fail!(symbol, expiration)
      @failed += 1
      Rails.cache.write(backoff_key(symbol, expiration), true, expires_in: FAILURE_BACKOFF)
    end

    def backed_off?(symbol, expiration) = Rails.cache.exist?(backoff_key(symbol, expiration))

    def backoff_key(symbol, expiration) = "option_quotes_refresher:backoff:#{symbol}:#{expiration || 'nearest'}"

    def expirations_key(symbol) = "option_quotes_refresher:expirations:#{symbol}:#{@today}"

    def expirations_for(symbol) = @expirations[symbol].presence || Rails.cache.read(expirations_key(symbol)).presence

    def remember_expirations(symbol, expirations)
      @expirations[symbol] = expirations if expirations.present?
      Rails.cache.write(expirations_key(symbol), expirations, expires_in: 1.day) if expirations.present?
    end

    # Upserts the requested expiration's contracts that are held or inside the
    # strike band around spot. Held contracts are never band-filtered. Returns
    # false when nothing usable came back.
    def store(symbol, expiration, data)
      spot = data[:underlying_price]
      quote_time = data[:quote_time]
      return false unless valid_quote_time?(quote_time)

      fetched_at = Time.current
      session_date = self.class.market_date(quote_time)

      rows = data[:rows].select { |row| row[:expiration] == expiration && row[:underlying] == symbol }
                        .select { |row| @held_symbols.include?(row[:contract_symbol]) || within_band?(row[:strike], spot) }
                        .uniq { |row| row[:contract_symbol] }
                        .map do |row|
                          row.slice(*QUOTE_FIELDS, :contract_symbol, :underlying, :option_type, :strike, :expiration)
                             .merge(underlying_price: spot, underlying_prev_close: data[:underlying_prev_close],
                                    quote_time: quote_time, session_date: session_date, fetched_at: fetched_at, source: "yahoo_finance")
                        end
      return false if rows.empty?

      write_rows(rows)
      true
    end

    def write_rows(rows)
      existing = OptionQuote.where(contract_symbol: rows.map { |row| row[:contract_symbol] }).index_by(&:contract_symbol)
      inserts = []

      OptionQuote.transaction do
        rows.each do |incoming|
          record = existing[incoming[:contract_symbol]]
          if record.nil?
            inserts << incoming
          else
            update_row(record, incoming)
          end
        end
        OptionQuote.insert_all(inserts, unique_by: :contract_symbol) if inserts.any?
      end
    end

    # Field-wise: inside one session a nil never replaces a stored figure. A
    # newer session first freezes the old session's mark (once, because the
    # stored session_date moves forward), then overwrites; an older session's
    # response is ignored.
    def update_row(record, incoming)
      old_session = record.session_date
      new_session = incoming[:session_date]
      return if old_session && new_session && new_session < old_session

      if old_session && new_session && new_session > old_session
        mark = frozen_mark(record)
        attrs = incoming.merge(prev_session_mark: mark, prev_session_date: mark && old_session)
      else
        attrs = incoming.reject { |field, value| value.nil? && QUOTE_FIELDS.include?(field) }
      end
      record.update!(attrs.except(:contract_symbol))
    end

    def frozen_mark(record)
      @session_mark_fn.call(record.attributes.symbolize_keys)
    rescue StandardError => e
      Rails.logger.warn("[OptionQuotes] session mark for #{record.contract_symbol} unavailable: #{e.class}: #{e.message.to_s.truncate(120)}")
      nil
    end

    def within_band?(strike, spot)
      return false if spot.nil? || spot <= 0

      strike.between?(spot * (1 - STRIKE_BAND), spot * (1 + STRIKE_BAND))
    end

    def last_fetched_at(symbol, expiration)
      OptionQuote.where(underlying: symbol, expiration: expiration).minimum(:fetched_at) || Time.at(0)
    end

    def underlying_fetched_at(symbol)
      OptionQuote.where(underlying: symbol).maximum(:fetched_at) || Time.at(0)
    end

    # Contracts that expired more than a week of market dates ago are of no use.
    def prune_expired
      OptionQuote.where("expiration < ?", @today - PRUNE_AFTER_DAYS).delete_all
    end
end
