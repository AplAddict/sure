# Refreshes cached stock data for the securities currently held. Runs from a
# scheduled job, never on page load. Stops at the first rate limit instead of
# retrying: the next run picks up where this one left off, and whatever was
# cached before stays on screen (stale, with its own "as of" time).
class Security::FundamentalsRefresher
  MAX_PER_RUN = 60
  RESEARCH_PER_RUN = 120
  PAUSE_BETWEEN_REQUESTS = 1.5
  YAHOO_SYMBOL = /\A[A-Z]{1,5}(\.[A-Z]{1,3})?\z/

  Result = Data.define(:refreshed, :failed, :skipped_for_rate_limit)

  def initialize(provider: Provider::YahooFinance.new, pause: PAUSE_BETWEEN_REQUESTS)
    @provider = provider
    @pause = pause
  end

  def self.held_securities
    held_ids = Holding.where("date >= ?", 10.days.ago.to_date).where("qty > 0").select(:security_id)

    Security.where(id: held_ids, offline: false, kind: "standard")
            .select { |security| security.ticker.to_s.match?(YAHOO_SYMBOL) }
  end

  # Browsable tickers nobody holds. Refreshed on their own, slower schedule so
  # the held securities above are always served first.
  def self.research_securities
    Security.research_only.where(kind: "standard").select { |security| security.ticker.to_s.match?(YAHOO_SYMBOL) }
  end

  def refresh_all(securities: self.class.held_securities, limit: MAX_PER_RUN)
    refreshed = 0
    failed = 0
    rate_limited = false

    SecurityFundamental.refresh_candidates(securities).first(limit).each do |security|
      case refresh(security)
      when :ok then refreshed += 1
      when :rate_limited
        rate_limited = true
        break
      else failed += 1
      end
      sleep(@pause) if @pause.positive?
    end

    Result.new(refreshed: refreshed, failed: failed, skipped_for_rate_limit: rate_limited)
  end

  def refresh(security)
    record = SecurityFundamental.find_or_initialize_by(security: security)
    record.last_attempt_at = Time.current

    response = @provider.fetch_security_fundamentals(
      symbol: security.ticker,
      exchange_operating_mic: security.exchange_operating_mic.presence
    )

    if response.success? && response.data.present?
      record.payload = response.data
      record.fetched_at = Time.current
      record.last_error = nil
      record.save!
      :ok
    else
      message = response.error&.message.to_s.truncate(200)
      record.last_error = message.presence || "No data returned"
      record.save!
      message.match?(/429|too many|rate limit/i) ? :rate_limited : :failed
    end
  end
end
