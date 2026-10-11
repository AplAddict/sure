require "test_helper"

class Security::ResearchUniverseTest < ActiveSupport::TestCase
  setup do
    @root = Pathname.new(Dir.mktmpdir)
    write("liquid_equity_universe_scan.json", tickers: [
      { symbol: "ZZUA", name: "Zed Unheld A", sector: "Utilities", regularMarketPrice: 10.0, score: 99, isPortfolioSymbol: true },
      { symbol: "ZZUB", name: "Zed Unheld B", sector: "Energy" },
      { symbol: "BAD SYM!", name: "Junk" },
      { symbol: "AAPL", name: "Apple" }
    ])
    write("quiver_research.json", symbols: { "QQXA" => {} })
    write("finviz_on_demand.json", symbols: { "FFXA" => {} })
    write("ticker_analysis.json", { "AANA" => {} })
    write("ticker_reports.json", { "RRXA" => [] })
    write("news.json", [ { "title" => "x", "tickers" => [ "nnxa", "AAPL" ] } ])
  end

  teardown { FileUtils.remove_entry(@root) }

  test "seeds an offline research-only security for every ticker in the artifacts" do
    created = Security::ResearchUniverse.new(root: @root).seed

    tickers = Security.research_only.pluck(:ticker)
    assert_equal %w[AANA FFXA NNXA QQXA RRXA ZZUA ZZUB].sort, tickers.sort
    assert_equal 7, created
    assert Security.research_only.all?(&:offline?)
    assert_equal "Zed Unheld A", Security.find_by!(ticker: "ZZUA").name
    assert_equal "Utilities", Security.find_by!(ticker: "ZZUA").sector
  end

  test "rejects symbols Yahoo cannot serve and never duplicates an existing security" do
    Security::ResearchUniverse.new(root: @root).seed

    assert_nil Security.find_by(ticker: "BAD SYM!")
    assert_equal 1, Security.where(ticker: "AAPL").count
    assert_not Security.find_by!(ticker: "AAPL").offline?, "an existing held security is left alone"
  end

  test "is idempotent" do
    Security::ResearchUniverse.new(root: @root).seed

    assert_no_difference "Security.count" do
      assert_equal 0, Security::ResearchUniverse.new(root: @root).seed
    end
  end

  test "research-only securities are skipped by the price importer and health checker" do
    Security::ResearchUniverse.new(root: @root).seed
    research = Security.research_only.first

    assert_not_includes Security.online, research
    assert_not_includes Security::HealthChecker.send(:checkable), research
    assert_includes Security::HealthChecker.send(:checkable), securities(:aapl)
  end

  test "a research-only security that gains a holding is brought online for pricing" do
    Security::ResearchUniverse.new(root: @root).seed
    bought = Security.research_only.find_by!(ticker: "ZZUA")
    untouched = Security.research_only.find_by!(ticker: "ZZUB")

    Security.activate_research_only([ bought.id ])

    assert_not bought.reload.offline?
    assert_nil bought.offline_reason
    assert_includes Security.online, bought
    assert untouched.reload.offline?, "tickers nobody holds stay research-only"
  end

  test "activation never touches a security that is offline for another reason" do
    broken = Security.create!(ticker: "ZZBK", name: "Broken", offline: true, offline_reason: "health_check_failed")

    Security.activate_research_only([ broken.id ])

    assert broken.reload.offline?
    assert_equal "health_check_failed", broken.offline_reason
  end

  test "a missing or malformed artifact seeds nothing and does not raise" do
    File.write(@root.join("liquid_equity_universe_scan.json"), "{ not json")
    FileUtils.rm(@root.join("quiver_research.json"))

    assert_nothing_raised { Security::ResearchUniverse.new(root: @root).seed }
  end

  private
    def write(name, data)
      File.write(@root.join(name), data.to_json)
    end
end
