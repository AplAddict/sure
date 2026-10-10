class SecurityHeadlineAnalysesRefreshJob < ApplicationJob
  queue_as :scheduled

  def perform
    results = SecurityFundamentalsRefresher.held_securities.map { |security| Security::HeadlineToneAnalyzer.new.analyze(security).status }
    Rails.logger.info("[SecurityHeadlineAnalyses] current=#{results.count('current')} unavailable=#{results.count('unavailable')} stale=#{results.count('stale')} failed=#{results.count('failed')}")
  end
end
