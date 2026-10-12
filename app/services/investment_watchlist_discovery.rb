# Deterministic, evidence-gated research queue generation. This is deliberately
# not a trading model: it can only queue one sourced item for a consenting user
# to research, never alter positions, prices, or an existing watchlist record.
#
# Candidates come from the market-wide liquid-equity scan (hundreds of US names
# with price, trend and relative-strength facts), then must also have fresh
# analyst data. Nothing is inferred: a missing, stale or unreadable input means
# no candidate that day.
class InvestmentWatchlistDiscovery
  Result = Data.define(:entry, :reason)

  SCAN_FILE = "liquid_equity_universe_scan.json".freeze
  SCAN_MAX_AGE = 36.hours
  FUNDAMENTALS_MAX_AGE = 36.hours
  MAX_ADDITIONS_PER_DAY = 1
  MIN_ANALYSTS = 5
  MIN_DOLLAR_VOLUME = 25_000_000
  MAX_20D_RETURN_PCT = 30.0      # not already stretched
  MIN_DISTANCE_FROM_HIGH_PCT = -25.0 # not in a deep drawdown
  EARNINGS_BLACKOUT_DAYS = 7

  Candidate = Data.define(:security, :score, :thesis)

  def initialize(user:, now: Time.current, scan: :load)
    @user = user
    @now = now
    @scan = scan
  end

  def add_candidate
    return Result.new(nil, :disabled) unless user.ai_watchlist_auto_add_enabled?
    return Result.new(nil, :daily_limit) if additions_today >= MAX_ADDITIONS_PER_DAY

    ResearchWatchlistEntry.purge_expired!(user: user)
    candidate = candidates.first
    return Result.new(nil, :no_fresh_evidence) unless candidate

    entry = user.research_watchlist_entries.create!(
      security: candidate.security,
      source: "assistant",
      status: "watching",
      priority: 3,
      expires_at: user.ai_watchlist_expiry_days.days.from_now,
      thesis: candidate.thesis
    )
    Result.new(entry, :added)
  rescue ActiveRecord::RecordNotUnique
    Result.new(nil, :already_queued)
  end

  private
    attr_reader :user, :now

    def additions_today
      user.research_watchlist_entries.where(source: "assistant").where(created_at: now.beginning_of_day..now.end_of_day).count
    end

    def candidates
      rows = scan_rows
      return [] if rows.empty?

      by_ticker = rows.index_by { |row| row["ticker"].to_s.upcase }
      excluded = excluded_security_ids
      Security.where(ticker: by_ticker.keys).includes(:fundamental).filter_map do |security|
        next if excluded.include?(security.id)

        row = by_ticker[security.ticker.to_s.upcase]
        fundamental = security.fundamental
        next unless trend_ok?(row) && fundamentals_ok?(fundamental)

        Candidate.new(security, score(row, fundamental), thesis_for(security, row, fundamental))
      end.sort_by { |candidate| [ -candidate.score, candidate.security.ticker ] }
    end

    # Only this member's own accessible holdings and own watchlist. The scan's
    # isPortfolioSymbol / isAgenticHeld flags describe other people's accounts and
    # are deliberately ignored.
    def excluded_security_ids
      held = Holding.where(account_id: user.accessible_accounts.visible.select(:id)).select(:security_id)
      Set.new(Holding.where(id: Holding.where(account_id: user.accessible_accounts.visible.select(:id)).select(:id)).pluck(:security_id) +
              user.research_watchlist_entries.active.pluck(:security_id) + held.pluck(:security_id))
    end

    def trend_ok?(row)
      avgs = row["aboveMovingAverages"].is_a?(Hash) ? row["aboveMovingAverages"] : {}
      return false if row["isETF"] == true || row["quoteType"].to_s != "EQUITY"
      return false unless %w[ma20 ma50 ma200].all? { |key| avgs[key] == true }
      return false unless number(row["regularDollarVolume"]) >= MIN_DOLLAR_VOLUME
      return false unless number(row["relativeStrength20dVsQQQ"]) > 0 && number(row["relativeStrength63dVsSPY"]) > 0
      return false if number(row["return20dPct"], default: 0) > MAX_20D_RETURN_PCT
      return false if number(row["distanceFrom52WeekHighPct"], default: -100) < MIN_DISTANCE_FROM_HIGH_PCT

      true
    end

    def fundamentals_ok?(fundamental)
      return false unless fundamental&.available? && fundamental.fetched_at >= now - FUNDAMENTALS_MAX_AGE
      return false unless %w[buy strong_buy].include?(fundamental.recommendation.to_s.downcase) && fundamental.analyst_count.to_i >= MIN_ANALYSTS

      earnings = Date.parse(fundamental.next_earnings_date.to_s) rescue nil
      !(earnings && earnings >= now.to_date && earnings <= now.to_date + EARNINGS_BLACKOUT_DAYS)
    end

    def score(row, fundamental)
      fundamental.analyst_count.to_i + number(row["relativeStrength20dVsQQQ"]) + number(row["relativeStrength63dVsSPY"]) / 2.0 +
        [ fundamental.revenue_growth.to_f, 0 ].max * 10 + [ fundamental.earnings_growth.to_f, 0 ].max * 5
    end

    def thesis_for(security, row, fundamental)
      facts = [
        "above its 20, 50 and 200-day averages",
        "ahead of QQQ by #{number(row['relativeStrength20dVsQQQ']).round(1)} pts over 20 days and SPY by #{number(row['relativeStrength63dVsSPY']).round(1)} pts over 63 days",
        "#{fundamental.recommendation.to_s.tr('_', ' ')} consensus from #{fundamental.analyst_count.to_i} analysts"
      ]
      facts << "revenue growth #{(fundamental.revenue_growth.to_f * 100).round(1)}%" if fundamental.revenue_growth.present?
      "Automated research candidate for #{security.ticker} (market scan #{scan_date}): #{facts.join('; ')}. Review the source material and risk before any decision; this is not a trade recommendation."
    end

    def number(value, default: -Float::INFINITY)
      Float(value)
    rescue ArgumentError, TypeError
      default
    end

    # The scan's own rows if it is recent and well formed, else nothing.
    def scan_rows
      data = @scan == :load ? load_scan : @scan
      return [] unless data.is_a?(Hash) && data["tickers"].is_a?(Array)

      generated = Time.iso8601(data["generatedAt"].to_s) rescue nil
      return [] if generated.nil? || generated < now - SCAN_MAX_AGE || generated > now + 5.minutes

      @scan_date = generated.to_date
      data["tickers"].select { |row| row.is_a?(Hash) && row["ticker"].to_s.match?(Security::ResearchUniverse::SYMBOL) }
    end

    def scan_date = @scan_date

    def load_scan
      path = Security::ResearchSnapshotImporter::ROOT.join(SCAN_FILE)
      path.file? ? JSON.parse(path.read) : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end
end
