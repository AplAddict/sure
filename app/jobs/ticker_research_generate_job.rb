# Builds a research page on demand for a ticker that has none yet (one nobody
# holds and no artifact mentions). Triggered by opening /research/tickers/XYZ,
# or by adding an unseen ticker to the research watchlist.
class TickerResearchGenerateJob < ApplicationJob
  queue_as :low_priority

  MISSING_TTL = 12.hours

  def self.missing_key(ticker)
    "research_ticker_missing:#{ticker}"
  end

  # Resolves a ticker to a research-only Security without the slow, rate-limited
  # fundamentals fetch. Returns [security, status] where status is :existing,
  # :created, :unknown (the market source answered "no such ticker"),
  # :unavailable (the lookup itself failed, so the ticker may still be valid)
  # or :invalid (not a plausible symbol; the market source is not contacted).
  def self.resolve_security(ticker, provider: nil)
    ticker = ticker.to_s.strip.upcase
    return [ nil, :invalid ] unless ticker.match?(Security::FundamentalsRefresher::YAHOO_SYMBOL)

    existing = Security.where("UPPER(ticker) = ?", ticker).order(:offline, :created_at).first
    return [ existing, :existing ] if existing

    provider ||= Provider::YahooFinance.new
    search = provider.search_securities(ticker)
    return [ nil, :unavailable ] unless search.success?

    match = search.data.find { |candidate| candidate.symbol.to_s.upcase == ticker }
    unless match
      # A real "no such ticker" answer is remembered. A failed lookup is not, so
      # a rate limit does not turn a valid ticker into a permanent 404.
      Rails.cache.write(missing_key(ticker), true, expires_in: MISSING_TTL)
      return [ nil, :unknown ]
    end

    security = Security.create!(
      ticker: ticker,
      name: match.name.presence,
      exchange_operating_mic: match.exchange_operating_mic.presence,
      country_code: match.country_code.presence,
      kind: "standard",
      offline: true,
      offline_reason: Security::RESEARCH_ONLY_REASON
    )
    [ security, :created ]
  rescue ActiveRecord::RecordNotUnique
    [ Security.where("UPPER(ticker) = ?", ticker).first, :existing ]
  end

  def perform(ticker, enrich_only: false)
    ticker = ticker.to_s.upcase
    return unless ticker.match?(Security::FundamentalsRefresher::YAHOO_SYMBOL)

    provider = Provider::YahooFinance.new

    if enrich_only
      security = Security.where("UPPER(ticker) = ?", ticker).order(:offline, :created_at).first
    else
      return if Security.where("UPPER(ticker) = ?", ticker).exists?

      security, = self.class.resolve_security(ticker, provider: provider)
    end
    return unless security

    Security::FundamentalsRefresher.new(provider: provider, pause: 0).refresh(security)
    Security::ResearchSnapshotImporter.new.import(security)
  end
end
