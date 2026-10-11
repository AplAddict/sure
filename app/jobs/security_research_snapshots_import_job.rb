class SecurityResearchSnapshotsImportJob < ApplicationJob
  queue_as :scheduled

  def perform
    Security::ResearchUniverse.new.seed

    securities = Security::FundamentalsRefresher.held_securities + Security.research_only.to_a
    result = Security::ResearchSnapshotImporter.new.import_all(securities: securities)
    Rails.logger.info("[SecurityResearchSnapshotsImport] imported=#{result.imported} unavailable=#{result.unavailable} invalid=#{result.invalid}")
  end
end
