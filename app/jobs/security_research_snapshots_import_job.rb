class SecurityResearchSnapshotsImportJob < ApplicationJob
  queue_as :scheduled

  def perform
    Security::ResearchUniverse.new.seed

    securities = Security::FundamentalsRefresher.held_securities + Security.research_only.to_a
    result = Security::ResearchSnapshotImporter.new.import_all(securities: securities)
    Rails.logger.info("[SecurityResearchSnapshotsImport] imported=#{result.imported} unavailable=#{result.unavailable} invalid=#{result.invalid}")

    # New or changed articles are analyzed as soon as they are imported. The
    # analyzer is digest-gated, so unchanged snapshots cost nothing.
    SecurityHeadlineAnalysesRefreshJob.perform_later
  end
end
