# Keeps today's price of currently held securities fresh while the US market is
# open, so day gain can be measured during the session instead of only after
# the nightly close import.
#
# It writes ONLY today's row, and only as a provisional price: the nightly
# import (Security::Price::Importer) treats provisional rows as refetchable and
# replaces them with the official close. A final or user-entered price is never
# touched. It does not create history, change holdings, or fetch securities
# nobody holds. A provider failure stops the run (one rate-limited request is
# the signal, not something to retry per ticker).
class Security::IntradayPriceRefresher
  Result = Data.define(:updated, :skipped, :rate_limited)

  MARKET_ZONE = "America/New_York".freeze
  OPEN = [ 9, 30 ].freeze
  CLOSE = [ 16, 15 ].freeze
  # Bounds one run so a large account cannot monopolise the provider quota.
  MAX_PER_RUN = 80
  # Seconds between provider requests. Measured against Yahoo from this host:
  # 29 of 29 requests at 1.5s apart succeeded, while a 0.5s burst is cut off
  # after about 15. 80 securities therefore take about two minutes per run.
  PACE_SECONDS = 1.5
  # Most requests a run may send to a non-Yahoo provider. Small on purpose: it
  # is a safety net for securities Yahoo cannot price, not a second feed.
  FALLBACK_LIMIT = 10

  def initialize(now: Time.current, limit: MAX_PER_RUN, pace: PACE_SECONDS)
    @now = now
    @limit = limit
    @pace = pace
    @fallbacks_used = 0
  end

  def market_open?
    local = @now.in_time_zone(MARKET_ZONE)
    return false unless local.to_date.on_weekday?

    local >= zone.local(local.year, local.month, local.day, *OPEN) && local <= zone.local(local.year, local.month, local.day, *CLOSE)
  end

  def refresh
    return Result.new(updated: 0, skipped: 0, rate_limited: false) unless market_open?

    today = @now.in_time_zone(MARKET_ZONE).to_date
    updated = skipped = 0

    securities.first(@limit).each_with_index do |security, index|
      sleep(@pace) if index.positive? && @pace.positive?
      response = fetch_quote(security, today)
      return Result.new(updated: updated, skipped: skipped, rate_limited: true) if response == :rate_limited
      next skipped += 1 if response.nil?

      quote = Array(response.data).find { |price| price.date == today }
      if quote.nil? || quote.price.to_d <= 0
        skipped += 1
        next
      end

      write(security, today, quote) ? updated += 1 : skipped += 1
    end

    Result.new(updated: updated, skipped: skipped, rate_limited: false)
  end

  private
    def zone = ActiveSupport::TimeZone[MARKET_ZONE]

    # Held now, tradable, and with a today row the nightly import owns (a row that
    # is missing or final is left alone).
    # Only securities with a provisional row for today: that is the only row
    # write() may change, so asking the provider about any other is a wasted
    # request against a limited quota. Stalest first: a row last written longest
    # ago (or before the open) goes to the front, so a run cut short by a rate
    # limit moves on to different securities next time instead of repeating.
    def securities
      held = Holding.where.not(qty: 0).where(date: Date.current - 3.days..).select(:security_id)
      today = @now.in_time_zone(MARKET_ZONE).to_date
      rows = Security::Price.where(date: today, provisional: true, security_id: held).pluck(:security_id, :updated_at).to_h
      Security.online.where(id: rows.keys).to_a.sort_by { |security| [ rows[security.id], security.ticker ] }
    end

    # Yahoo is the polling source: free, keyless and not credit-limited. Keyed
    # providers (Twelve Data 800/day, Tiingo 1,000/day) are listed first by the
    # settings UI, but polling them every 20 minutes would exhaust their daily
    # quota, so they are only a capped fallback for what Yahoo cannot price. A
    # security pinned to one provider is polled through that provider alone.
    # Returns the provider response, nil for "no usable quote", or :rate_limited.
    def fetch_quote(security, today)
      return request(security.price_data_provider, security, today) if security.price_provider.present?

      primary, *others = enabled_providers.sort_by { |provider| provider.is_a?(Provider::YahooFinance) ? 0 : 1 }
      response = request(primary, security, today)
      return response if response.nil? || response.success?
      return :rate_limited if rate_limited?(response)

      fallback = others.first
      return response if fallback.nil? || @fallbacks_used >= FALLBACK_LIMIT

      @fallbacks_used += 1
      request(fallback, security, today)
    end

    def request(provider, security, today)
      return nil if provider.nil?

      response = provider.fetch_security_prices(symbol: security.ticker, exchange_operating_mic: security.exchange_operating_mic, start_date: today - 1.day, end_date: today)
      Rails.logger.warn("[IntradayPriceRefresher] #{security.ticker}: #{response.error&.message.to_s.truncate(120)}") unless response.success?
      response
    end

    def rate_limited?(response)
      error = response.error
      error.is_a?(Provider::YahooFinance::RateLimitError) || error.to_s.match?(/429|rate limit|too many/i)
    end

    def enabled_providers
      @enabled_providers ||= Security.providers.reject { |provider| provider.is_a?(Provider::BinancePublic) }
    end

    def write(security, date, quote)
      row = Security::Price.find_by(security_id: security.id, date: date)
      return false if row.nil? || !row.provisional
      return false if row.currency != quote.currency

      row.update!(price: quote.price, updated_at: Time.current)
      true
    end
end
