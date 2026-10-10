class SecurityResearchSnapshotsImportJob < ApplicationJob
  queue_as :scheduled

  def perform
    result = Security::ResearchSnapshotImporter.new.import_all
    Rails.logger.info("[SecurityResearchSnapshotsImport] imported=#{result.imported} unavailable=#{result.unavailable} invalid=#{result.invalid}")
  end
end
