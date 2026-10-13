require "test_helper"

class SecurityHeadlineAnalysesRefreshJobTest < ActiveJob::TestCase
  test "analyzes every held security so new imported articles receive sentiment" do
    first = securities(:aapl)
    second = securities(:msft)
    Security::FundamentalsRefresher.stubs(:held_securities).returns([ first, second ])
    analyzed = []
    analyzer = mock
    analyzer.stubs(:analyze).with { |security| analyzed << security; true }.returns(SecurityHeadlineAnalysis.new(status: "current"))
    Security::HeadlineToneAnalyzer.stubs(:new).returns(analyzer)

    SecurityHeadlineAnalysesRefreshJob.perform_now

    assert_equal [ first, second ], analyzed
  end

  test "one failing security does not stop the rest of the run" do
    first = securities(:aapl)
    second = securities(:msft)
    Security::FundamentalsRefresher.stubs(:held_securities).returns([ first, second ])
    analyzed = []
    failing = mock
    failing.stubs(:analyze).raises(ActiveRecord::RecordInvalid)
    healthy = mock
    healthy.stubs(:analyze).with { |security| analyzed << security; true }.returns(SecurityHeadlineAnalysis.new(status: "current"))
    Security::HeadlineToneAnalyzer.stubs(:new).returns(failing, healthy)

    assert_nothing_raised { SecurityHeadlineAnalysesRefreshJob.perform_now }

    assert_equal [ second ], analyzed
  end

  test "the research snapshot import queues the analysis so fresh articles are not left waiting for the next cron" do
    Security::ResearchUniverse.any_instance.stubs(:seed)
    Security::FundamentalsRefresher.stubs(:held_securities).returns([])
    Security::ResearchSnapshotImporter.any_instance.stubs(:import_all).returns(Struct.new(:imported, :unavailable, :invalid).new(1, 0, 0))

    assert_enqueued_with(job: SecurityHeadlineAnalysesRefreshJob) do
      SecurityResearchSnapshotsImportJob.perform_now
    end
  end
end
