# Refreshes market quotes for held option contracts and idea-scan chains.
# Never raises: whatever was cached stays on screen with its own as-of, and the
# next run picks up where this one stopped.
#
# The schedule fires on a fixed UTC grid; whether a firing does anything is
# decided here, against the exchange calendar: during the session, or in the
# settle window around the applicable New York close plus 20 minutes (the final
# refresh after the close, so tomorrow's day change has a settled baseline).
class OptionQuotesRefreshJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  # Settle run: 20 minutes after the applicable New York close, +/- 10 minutes.
  SETTLE_DELAY = 20.minutes
  SETTLE_TOLERANCE = 10.minutes

  # Default calendar. Options::MarketCalendar ships separately, so it is only
  # resolved when asked, never when this file loads.
  class DefaultCalendar
    def session_open?(now) = Options::MarketCalendar.session_open?(now)

    def final_window?(now)
      date = Options::MarketCalendar.market_date(now)
      return false unless Options::MarketCalendar.trading_day?(date)

      (now - (Options::MarketCalendar.close_time(date) + SETTLE_DELAY)).abs <= SETTLE_TOLERANCE
    end
  end

  # An object answering session_open?(time) and final_window?(time).
  attr_writer :calendar

  def calendar = @calendar ||= DefaultCalendar.new

  def perform
    return if Rails.env.development?

    now = Time.current
    return unless calendar.session_open?(now) || calendar.final_window?(now)

    result = OptionQuote::Refresher.new.refresh_all
    Rails.logger.info("[OptionQuotesRefresh] refreshed=#{result.refreshed} failed=#{result.failed} requests=#{result.requests} backed_off=#{result.backed_off} pruned=#{result.pruned} rate_limited=#{result.skipped_for_rate_limit}")
  rescue StandardError => e
    Rails.logger.error("[OptionQuotesRefresh] aborted: #{e.class}: #{e.message.to_s.truncate(200)}")
  end
end
