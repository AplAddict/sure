class SecurityHeadlineAnalysesRefreshJob < ApplicationJob
  queue_as :scheduled

  def perform
    results = Security::FundamentalsRefresher.held_securities.map do |security|
      # A single bad security must not stop sentiment for the rest of the run.
      Security::HeadlineToneAnalyzer.new.analyze(security).status
    rescue StandardError => error
      Rails.logger.warn("[SecurityHeadlineAnalyses] security=#{security.id} #{error.class}: #{error.message.truncate(160)}")
      "failed"
    end
    Rails.logger.info("[SecurityHeadlineAnalyses] current=#{results.count('current')} unavailable=#{results.count('unavailable')} stale=#{results.count('stale')} failed=#{results.count('failed')}")
  end
end
