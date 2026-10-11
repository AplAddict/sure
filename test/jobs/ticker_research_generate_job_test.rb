require "test_helper"

class TickerResearchGenerateJobTest < ActiveJob::TestCase
  Result = Struct.new(:data, :ok) do
    def success? = ok
  end

  setup do
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @provider = mock("yahoo")
    Provider::YahooFinance.stubs(:new).returns(@provider)
    Security::FundamentalsRefresher.any_instance.stubs(:refresh).returns(:ok)
    Security::ResearchSnapshotImporter.any_instance.stubs(:import).returns(:unavailable)
  end

  teardown { Rails.cache = @original_cache }

  test "creates an offline research-only security when the market source knows the ticker" do
    match = Provider::SecurityConcept::Security.new(symbol: "ZZJA", name: "Job Test Corp", logo_url: nil, exchange_operating_mic: "XNAS", country_code: "US")
    @provider.expects(:search_securities).with("ZZJA").returns(Result.new([ match ], true))

    assert_difference "Security.count", 1 do
      TickerResearchGenerateJob.perform_now("zzja")
    end

    security = Security.find_by!(ticker: "ZZJA")
    assert security.offline?
    assert_equal Security::RESEARCH_ONLY_REASON, security.offline_reason
    assert_equal "Job Test Corp", security.name
  end

  test "remembers a genuine no-such-ticker answer so it is not retried" do
    @provider.expects(:search_securities).returns(Result.new([], true))

    assert_no_difference "Security.count" do
      TickerResearchGenerateJob.perform_now("ZZJB")
    end

    assert Rails.cache.read(TickerResearchGenerateJob.missing_key("ZZJB"))
  end

  test "a failed lookup is not remembered as missing" do
    @provider.expects(:search_securities).returns(Result.new(nil, false))

    TickerResearchGenerateJob.perform_now("ZZJC")

    assert_nil Rails.cache.read(TickerResearchGenerateJob.missing_key("ZZJC"))
    assert_nil Security.find_by(ticker: "ZZJC")
  end

  test "does nothing for an invalid symbol or one that already exists" do
    @provider.expects(:search_securities).never

    assert_no_difference "Security.count" do
      TickerResearchGenerateJob.perform_now("bad symbol!!")
      TickerResearchGenerateJob.perform_now("AAPL")
    end
  end
end
