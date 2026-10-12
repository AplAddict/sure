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

  def initialize(now: Time.current, limit: MAX_PER_RUN, pace: PACE_SECONDS)
    @now = now
    @limit = limit
    @pace = pace
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
      provider = security.price_data_provider
      next skipped += 1 if provider.nil?

      response = provider.fetch_security_prices(symbol: security.ticker, exchange_operating_mic: security.exchange_operating_mic, start_date: today - 1.day, end_date: today)
      unless response.success?
        Rails.logger.warn("[IntradayPriceRefresher] #{security.ticker}: #{response.error&.message.to_s.truncate(120)}")
        return Result.new(updated: updated, skipped: skipped, rate_limited: true)
      end

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
    # Stalest first: a row last written longest ago (or before the open) goes to
    # the front, so a run cut short by a rate limit moves on to different
    # securities next time instead of re-fetching the same few.
    def securities
      held = Holding.where.not(qty: 0).where(date: Date.current - 3.days..).select(:security_id)
      stale_since = Security::Price.where(date: @now.in_time_zone(MARKET_ZONE).to_date).group(:security_id).minimum(:updated_at)
      Security.online.where(id: held).to_a.sort_by { |security| [ stale_since[security.id] || Time.at(0), security.ticker ] }
    end

    def write(security, date, quote)
      row = Security::Price.find_by(security_id: security.id, date: date)
      return false if row.nil? || !row.provisional
      return false if row.currency != quote.currency

      row.update!(price: quote.price, updated_at: Time.current)
      true
    end
end
