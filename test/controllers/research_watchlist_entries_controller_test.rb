require "test_helper"

class ResearchWatchlistEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:family_admin)
    @member = users(:family_member)
    @security = Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Queue Test")
    @entry = ResearchWatchlistEntry.create!(user: @owner, security: @security, status: "researching", priority: 2, thesis: "Owner-only thesis")
  end

  test "shows only the signed-in user's thesis queue" do
    sign_in @owner
    get research_watchlist_entries_path

    assert_response :success
    assert_match "Owner-only thesis", response.body
    assert_match @security.ticker, response.body
  end

  test "does not expose another family member's thesis queue" do
    sign_in @member
    get research_watchlist_entries_path

    assert_response :success
    assert_no_match "Owner-only thesis", response.body
    assert_no_match @security.ticker, response.body
  end

  test "creates an entry for a known ticker for the signed-in user only" do
    other = Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Add Test")
    sign_in @owner

    assert_difference -> { @owner.research_watchlist_entries.count }, 1 do
      assert_no_difference -> { @member.research_watchlist_entries.count } do
        post research_watchlist_entries_path, params: { research_watchlist_entry: { ticker: other.ticker, status: "watching", priority: 1, thesis: "Check margins" } }
      end
    end

    assert_redirected_to research_watchlist_entries_path
  end

  Lookup = Struct.new(:data, :ok) do
    def success? = ok
  end

  test "an unknown ticker the market source recognises is resolved and added" do
    ticker = letters_ticker
    match = Provider::SecurityConcept::Security.new(symbol: ticker, name: "Resolved Corp", logo_url: nil, exchange_operating_mic: "XNAS", country_code: "US")
    provider = mock("yahoo")
    provider.expects(:search_securities).with(ticker).returns(Lookup.new([ match ], true))
    Provider::YahooFinance.stubs(:new).returns(provider)
    sign_in @owner

    assert_difference [ "Security.count", "@owner.research_watchlist_entries.count" ], 1 do
      post research_watchlist_entries_path, params: { research_watchlist_entry: { ticker: ticker.downcase, status: "watching", priority: 3, thesis: "New name" } }
    end

    security = Security.find_by!(ticker: ticker)
    assert security.offline?
    assert_equal Security::RESEARCH_ONLY_REASON, security.offline_reason
    assert_redirected_to research_watchlist_entries_path
    assert_enqueued_with(job: TickerResearchGenerateJob, args: [ ticker, { enrich_only: true } ])
  end

  test "a ticker the market source does not know is rejected without creating anything" do
    ticker = letters_ticker
    provider = mock("yahoo")
    provider.expects(:search_securities).with(ticker).returns(Lookup.new([], true))
    Provider::YahooFinance.stubs(:new).returns(provider)
    sign_in @owner

    assert_no_difference [ "ResearchWatchlistEntry.count", "Security.count" ] do
      post research_watchlist_entries_path, params: { research_watchlist_entry: { ticker: ticker, status: "watching", priority: 3 } }
    end

    assert_response :unprocessable_entity
    assert_match "isn&#39;t a known ticker", response.body
  end

  test "a failed market lookup says so and creates nothing, so a valid ticker is not wrongly called unknown" do
    provider = mock("yahoo")
    provider.expects(:search_securities).returns(Lookup.new(nil, false))
    Provider::YahooFinance.stubs(:new).returns(provider)
    sign_in @owner

    assert_no_difference [ "ResearchWatchlistEntry.count", "Security.count" ] do
      post research_watchlist_entries_path, params: { research_watchlist_entry: { ticker: letters_ticker, status: "watching", priority: 3 } }
    end

    assert_response :unprocessable_entity
    assert_match "couldn&#39;t be checked right now", response.body
  end

  test "a malformed ticker is rejected without calling the market source" do
    Provider::YahooFinance.expects(:new).never
    sign_in @owner

    assert_no_difference "ResearchWatchlistEntry.count" do
      post research_watchlist_entries_path, params: { research_watchlist_entry: { ticker: "bad symbol!!", status: "watching", priority: 3 } }
    end

    assert_response :unprocessable_entity
  end

  test "updates only the owner's entry" do
    sign_in @owner
    patch research_watchlist_entry_path(@entry), params: { research_watchlist_entry: { status: "ready", priority: 1, thesis: "Updated" } }

    assert_redirected_to research_watchlist_entries_path
    assert_equal "ready", @entry.reload.status
    assert_equal "Updated", @entry.thesis
  end

  test "another user cannot update or delete an entry" do
    sign_in @member

    patch research_watchlist_entry_path(@entry), params: { research_watchlist_entry: { status: "archived" } }
    assert_response :not_found
    delete research_watchlist_entry_path(@entry)
    assert_response :not_found

    assert_equal "researching", @entry.reload.status
  end

  test "owner can remove an entry" do
    sign_in @owner

    assert_difference -> { @owner.research_watchlist_entries.count }, -1 do
      delete research_watchlist_entry_path(@entry)
    end
  end

  private
    # The market-source symbol pattern allows 1-5 letters, so test tickers must too.
    def letters_ticker
      Array.new(5) { ("A".."Z").to_a.sample }.join
    end
end
