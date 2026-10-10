class SecurityFundamentalsRefreshJob < ApplicationJob
  queue_as :scheduled

  def perform
    return if Rails.env.development?

    result = Security::FundamentalsRefresher.new.refresh_all
    Rails.logger.info("[SecurityFundamentalsRefresh] refreshed=#{result.refreshed} failed=#{result.failed} rate_limited=#{result.skipped_for_rate_limit}")
  end
end
