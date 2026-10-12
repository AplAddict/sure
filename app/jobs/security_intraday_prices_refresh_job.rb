# Weekday market-hours refresh of held securities' live prices. See
# Security::IntradayPriceRefresher for the safety rules.
class SecurityIntradayPricesRefreshJob < ApplicationJob
  queue_as :scheduled

  def perform
    return if Rails.env.development?

    result = Security::IntradayPriceRefresher.new.refresh
    Rails.logger.info("[SecurityIntradayPricesRefresh] updated=#{result.updated} skipped=#{result.skipped} rate_limited=#{result.rate_limited}")
  end
end
