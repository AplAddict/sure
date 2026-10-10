require "test_helper"
require "tmpdir"

class SecurityResearchSnapshotImporterTest < ActiveSupport::TestCase
  setup { @security = securities(:aapl) }

  test "imports static research without changing a holding or price" do
    Dir.mktmpdir do |dir|
      write_artifacts(dir)
      before = [ Holding.count, Security::Price.count ]

      result = Security::ResearchSnapshotImporter.new(root: dir, now: Time.zone.parse("2026-10-10 12:00 UTC")).import_all(securities: [ @security ])

      snapshot = @security.reload.research_snapshot
      assert_equal 1, result.imported
      assert_equal before, [ Holding.count, Security::Price.count ]
      assert_equal "current", snapshot.status
      assert_equal "AAPL research note", snapshot.section("analysis")
      assert_equal 0.52, snapshot.section("quiver").dig("metrics", "darkPool", "latestDpi")
      assert_equal 61.2, snapshot.section("finviz").dig("metrics", "rsi14")
      assert_equal 1, snapshot.section("news").size
    end
  end

  test "missing mount is unavailable and never fabricates payload" do
    result = Security::ResearchSnapshotImporter.new(root: "/not-mounted", now: Time.current).import_all(securities: [ @security ])

    assert_equal 1, result.unavailable
    snapshot = @security.reload.research_snapshot
    assert_equal "unavailable", snapshot.status
    assert_equal({}, snapshot.payload)
  end

  private

  def write_artifacts(dir)
    File.write(File.join(dir, "quiver_research.json"), { generatedAt: "2026-10-10T10:00:00Z", symbols: { "AAPL" => { metrics: { darkPool: { latestDpi: 0.52 } } } } }.to_json)
    File.write(File.join(dir, "finviz_on_demand.json"), { symbols: { "AAPL" => { metrics: { rsi14: 61.2 } } } }.to_json)
    File.write(File.join(dir, "ticker_analysis.json"), { "AAPL" => "AAPL research note" }.to_json)
    File.write(File.join(dir, "ticker_reports.json"), { "AAPL" => [ { title: "Report" } ] }.to_json)
    File.write(File.join(dir, "news.json"), [ { title: "Apple story", tickers: [ "AAPL" ] }, { title: "Other", tickers: [ "MSFT" ] } ].to_json)
  end
end
