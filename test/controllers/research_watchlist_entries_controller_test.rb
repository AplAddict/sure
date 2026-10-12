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

  test "market lookups for unseen tickers are limited per user, while known tickers stay free" do
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    provider = mock("yahoo")
    provider.stubs(:search_securities).returns(Lookup.new([], true))
    Provider::YahooFinance.stubs(:new).returns(provider)
    sign_in @owner

    ResearchWatchlistEntriesController::LOOKUPS_PER_MINUTE.times do
      post research_watchlist_entries_path, params: { research_watchlist_entry: { ticker: letters_ticker, status: "watching", priority: 3 } }
      assert_response :unprocessable_entity
    end
    post research_watchlist_entries_path, params: { research_watchlist_entry: { ticker: letters_ticker, status: "watching", priority: 3 } }

    assert_response :too_many_requests
    assert_match "too many", response.body.downcase

    known = Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Known Free")
    assert_difference -> { @owner.research_watchlist_entries.count }, 1 do
      post research_watchlist_entries_path, params: { research_watchlist_entry: { ticker: known.ticker, status: "watching", priority: 3 } }
    end
  ensure
    Rails.cache = original
  end

  test "a failed add keeps what the user typed" do
    provider = mock("yahoo")
    provider.stubs(:search_securities).returns(Lookup.new([], true))
    Provider::YahooFinance.stubs(:new).returns(provider)
    sign_in @owner

    post research_watchlist_entries_path, params: { research_watchlist_entry: { ticker: "ZZQQX", status: "researching", priority: 2, thesis: "Keep this text" } }

    assert_response :unprocessable_entity
    assert_select "input[name='research_watchlist_entry[ticker]'][value=ZZQQX]"
    assert_select "input[name='research_watchlist_entry[thesis]'][value=?], textarea[name='research_watchlist_entry[thesis]']", "Keep this text"
    assert_select "option[selected][value=researching]"
  end

  test "an invalid update shows its error beside the edited row and leaves the add form alone" do
    sign_in @owner

    patch research_watchlist_entry_path(@entry), params: { research_watchlist_entry: { status: "bogus", priority: 9, thesis: "x" } }

    assert_response :unprocessable_entity
    assert_select "[data-testid='watchlist-row-#{@entry.id}'] [role=alert]"
    assert_select "[data-testid='watchlist-add'] [role=alert]", count: 0
    assert_equal "researching", @entry.reload.status
  end

  test "entries the assistant added are labeled, and the member can still edit or remove them" do
    ai_security = Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Assistant Pick")
    ai_entry = ResearchWatchlistEntry.create!(user: @owner, security: ai_security, source: "assistant")
    sign_in @owner

    get research_watchlist_entries_path
    assert_select "[data-testid='watchlist-row-#{ai_entry.id}']", text: /Added by assistant/
    assert_select "[data-testid='watchlist-row-#{@entry.id}']", text: /Added by assistant/, count: 0

    assert_difference -> { @owner.research_watchlist_entries.count }, -1 do
      delete research_watchlist_entry_path(ai_entry)
    end
  end

  test "assistant entries show when they expire, expired ones are hidden, and Keep makes one permanent" do
    live = ResearchWatchlistEntry.create!(user: @owner, security: Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Live Ai"), source: "assistant", expires_at: 5.days.from_now)
    gone = ResearchWatchlistEntry.create!(user: @owner, security: Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Gone Ai"), source: "assistant", expires_at: 1.hour.ago)
    sign_in @owner

    get research_watchlist_entries_path
    assert_select "[data-testid='watchlist-row-#{live.id}']", text: /Expires in/
    assert_select "[data-testid='watchlist-row-#{gone.id}']", count: 0
    assert_select "[data-testid='watchlist-row-#{live.id}'] form[action=?]", research_watchlist_entry_path(live)

    patch research_watchlist_entry_path(live), params: { keep: "1" }
    assert_redirected_to research_watchlist_entries_path
    assert_nil live.reload.expires_at
    assert_equal "assistant", live.source, "the label stays so the origin is still visible"
  end

  test "editing an assistant entry counts as reviewing it and stops the expiry" do
    entry = ResearchWatchlistEntry.create!(user: @owner, security: Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Edit Ai"), source: "assistant", expires_at: 3.days.from_now)
    sign_in @owner

    patch research_watchlist_entry_path(entry), params: { research_watchlist_entry: { status: "researching", priority: 2, thesis: "Looked at it" } }

    assert_nil entry.reload.expires_at
  end

  test "a manual add over an expired assistant leftover replaces it instead of failing" do
    sec = Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Leftover")
    ResearchWatchlistEntry.create!(user: @owner, security: sec, source: "assistant", expires_at: 1.hour.ago)
    sign_in @owner

    post research_watchlist_entries_path, params: { research_watchlist_entry: { ticker: sec.ticker, status: "watching", priority: 3 } }

    assert_redirected_to research_watchlist_entries_path
    entry = @owner.research_watchlist_entries.find_by!(security: sec)
    assert_equal "user", entry.source
    assert_nil entry.expires_at
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

  def fundamentals_for(security, payload, fetched_at: Time.current)
    SecurityFundamental.create!(security: security, payload: payload, fetched_at: fetched_at)
  end

  test "shows next earnings, analyst target and 52-week range from cached fundamentals with their age" do
    fundamentals_for(@security, { "next_earnings_date" => (Date.current + 9).iso8601, "target_mean_price" => 150.5, "fifty_two_week_low" => 90, "fifty_two_week_high" => 160, "currency" => "USD" }, fetched_at: 3.hours.ago)
    sign_in @owner
    get research_watchlist_entries_path

    assert_select "[data-testid=watchlist-row-#{@entry.id}] [data-testid=watchlist-earnings]", text: /in 9 days|Oct|Nov/
    assert_select "[data-testid=watchlist-row-#{@entry.id}] [data-testid=watchlist-target]", text: /150\.50/
    assert_select "[data-testid=watchlist-row-#{@entry.id}] [data-testid=watchlist-range]", text: /90.*160/
    assert_select "[data-testid=watchlist-row-#{@entry.id}] [data-testid=watchlist-data-age]", text: /3 hours/
  end

  test "missing fundamentals show an unavailable dash, never zero" do
    sign_in @owner
    get research_watchlist_entries_path

    assert_select "[data-testid=watchlist-row-#{@entry.id}] [data-testid=watchlist-earnings]", text: /—/
    assert_select "[data-testid=watchlist-row-#{@entry.id}] [data-testid=watchlist-target]", text: /—/
    assert_no_match(/\$0\.00/, css_select("[data-testid=watchlist-row-#{@entry.id}]").to_s)
  end

  test "earnings within a week are flagged and a past date is not shown as upcoming" do
    soon = Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Soon")
    past = Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Past")
    soon_entry = ResearchWatchlistEntry.create!(user: @owner, security: soon, status: "watching", priority: 3)
    past_entry = ResearchWatchlistEntry.create!(user: @owner, security: past, status: "watching", priority: 3)
    fundamentals_for(soon, { "next_earnings_date" => (Date.current + 3).iso8601 })
    fundamentals_for(past, { "next_earnings_date" => (Date.current - 20).iso8601 })
    sign_in @owner
    get research_watchlist_entries_path

    assert_select "[data-testid=watchlist-row-#{soon_entry.id}] [data-testid=watchlist-earnings-soon]"
    assert_select "[data-testid=watchlist-row-#{past_entry.id}] [data-testid=watchlist-earnings-soon]", count: 0
    assert_select "[data-testid=watchlist-row-#{past_entry.id}] [data-testid=watchlist-earnings]", text: /—/
  end

  test "filters by status and offers a filter for each status with counts" do
    other = Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Ready One")
    ResearchWatchlistEntry.create!(user: @owner, security: other, status: "ready", priority: 1, thesis: "Ready thesis")
    sign_in @owner

    get research_watchlist_entries_path(status: "ready")
    assert_response :success
    assert_match "Ready thesis", response.body
    assert_no_match "Owner-only thesis", response.body
    assert_select "[data-testid=watchlist-filters] a[aria-current=true]", text: /Ready/
    assert_select "[data-testid=watchlist-filters] a", minimum: 4

    get research_watchlist_entries_path(status: "nonsense")
    assert_match "Owner-only thesis", response.body
    assert_match "Ready thesis", response.body
  end

  test "a filter never reveals another member's entries" do
    sign_in @member
    get research_watchlist_entries_path(status: "researching")
    assert_response :success
    assert_no_match "Owner-only thesis", response.body
  end

  test "the edit form sits behind a disclosure so rows stay compact" do
    sign_in @owner
    get research_watchlist_entries_path

    assert_select "[data-testid=watchlist-row-#{@entry.id}] details summary", text: /Edit/
    assert_select "[data-testid=watchlist-row-#{@entry.id}] details form"
    assert_select "[data-testid=watchlist-row-#{@entry.id}] p[data-testid=watchlist-thesis]", text: /Owner-only thesis/
  end

  test "a row that failed validation opens its edit form" do
    sign_in @owner
    patch research_watchlist_entry_path(@entry), params: { research_watchlist_entry: { status: "bogus" } }

    assert_response :unprocessable_entity
    assert_select "[data-testid=watchlist-row-#{@entry.id}] details[open]"
  end

  test "watchlist add form and saved list are draggable sections" do
    sign_in @owner
    get research_watchlist_entries_path

    assert_response :success
    assert_equal %w[add saved], css_select("[data-reports-sortable-target=section]").map { |n| n["data-section-key"] }
    assert_select "[data-section-key=add] [data-testid=watchlist-add]"
    assert_select "[data-section-key=saved] [data-testid=watchlist-row-#{@entry.id}]"
  end

end
