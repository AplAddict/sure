# Keeps stock data flowing for browsable tickers nobody holds. It also seeds new
# tickers and gives each a research snapshot as soon as one is possible, so a
# freshly added ticker has a page without waiting for the nightly import.
class SecurityResearchUniverseRefreshJob < ApplicationJob
  queue_as :scheduled

  def perform
    return if Rails.env.development?

    created = Security::ResearchUniverse.new.seed

    fresh = Security.research_only.where.missing(:research_snapshot).to_a
    Security::ResearchSnapshotImporter.new.import_all(securities: fresh) if fresh.any?

    result = Security::FundamentalsRefresher.new.refresh_all(
      securities: Security::FundamentalsRefresher.research_securities,
      limit: Security::FundamentalsRefresher::RESEARCH_PER_RUN
    )
    Rails.logger.info("[SecurityResearchUniverseRefresh] created=#{created} refreshed=#{result.refreshed} failed=#{result.failed} rate_limited=#{result.skipped_for_rate_limit}")
  end
end
