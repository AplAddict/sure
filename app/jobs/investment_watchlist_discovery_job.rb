class InvestmentWatchlistDiscoveryJob < ApplicationJob
  queue_as :scheduled

  def perform
    User.find_each do |user|
      result = InvestmentWatchlistDiscovery.new(user: user).add_candidate
      Rails.logger.info("[InvestmentWatchlistDiscovery] user=#{user.id} result=#{result.reason} ticker=#{result.entry&.security&.ticker}")
    rescue StandardError => error
      Rails.logger.warn("[InvestmentWatchlistDiscovery] user=#{user.id} error=#{error.class}: #{error.message.truncate(180)}")
    end
  end
end
