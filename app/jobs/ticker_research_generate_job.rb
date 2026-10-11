# Builds a research page on demand for a ticker that has none yet (one nobody
# holds and no artifact mentions). Triggered by opening /research/tickers/XYZ.
class TickerResearchGenerateJob < ApplicationJob
  queue_as :low_priority

  MISSING_TTL = 12.hours

  def self.missing_key(ticker)
    "research_ticker_missing:#{ticker}"
  end

  def perform(ticker)
    ticker = ticker.to_s.upcase
    return unless ticker.match?(Security::FundamentalsRefresher::YAHOO_SYMBOL)
    return if Security.where("UPPER(ticker) = ?", ticker).exists?

    provider = Provider::YahooFinance.new
    search = provider.search_securities(ticker)
    match = search.success? ? search.data.find { |candidate| candidate.ticker.to_s.upcase == ticker } : nil

    unless match
      # A real "no such ticker" answer is remembered. A failed lookup is not, so
      # a rate limit does not turn a valid ticker into a permanent 404.
      Rails.cache.write(self.class.missing_key(ticker), true, expires_in: MISSING_TTL) if search.success?
      return
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

    Security::FundamentalsRefresher.new(provider: provider, pause: 0).refresh(security)
    Security::ResearchSnapshotImporter.new.import(security)
  rescue ActiveRecord::RecordNotUnique
    nil
  end
end
