require "test_helper"

class ResearchUnheldTickersTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    ensure_tailwind_build
    @user = users(:family_admin)
    sign_in @user
    # The test env uses :null_store; the pending/missing flags need a real one.
    @original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  teardown { Rails.cache = @original_cache }

  def research_only!(ticker, name: "Unheld #{ticker}")
    Security.create!(ticker: ticker, name: name, offline: true, offline_reason: Security::RESEARCH_ONLY_REASON, country_code: "US")
  end

  def snapshot!(security, scan:)
    SecurityResearchSnapshot.create!(
      security: security, status: "current", generated_at: Time.current, imported_at: Time.current,
      payload: { "scan" => scan }
    )
  end

  test "a ticker nobody holds has a research page with a market snapshot and no position sections" do
    security = research_only!("ZZUA")
    snapshot!(security, scan: { "regularMarketPrice" => 12.5, "changePct" => -1.2, "return20dPct" => 4.0,
                                "fiftyTwoWeekLow" => 8, "fiftyTwoWeekHigh" => 20, "ma20" => 11, "ma50" => 10, "ma200" => 9, "sector" => "Energy" })

    get research_ticker_path("zzua")

    assert_response :success
    assert_select "[data-testid=market-snapshot]", text: /Not held in your accounts/
    assert_select "[data-testid=market-snapshot]", text: /\$12\.50/
    assert_select "h2", text: "Equity positions & cost basis", count: 0
    assert_select "h2", text: "Purchase activity & tax lots", count: 0
    assert_select "h2", text: "Options positions", count: 0
    assert_select "h2", text: "Fundamentals & stock data"
    assert_select "h2", text: "News"
  end

  test "missing figures read unavailable, never zero" do
    security = research_only!("ZZUB")
    snapshot!(security, scan: { "regularMarketPrice" => 12.5 })

    get research_ticker_path("ZZUB")

    assert_response :success
    assert_select "[data-testid=market-snapshot]", text: /Unavailable/
    assert_select "[data-testid=market-snapshot]", text: /\+0\.0%|\b0\.0%/, count: 0
  end

  test "a research-only ticker with no scan data still renders" do
    research_only!("ZZUC")

    get research_ticker_path("ZZUC")

    assert_response :success
    assert_select "[data-testid=market-snapshot-unavailable]"
  end

  test "a security another family holds shows none of their positions" do
    other_family_security = research_only!("ZZUD")
    other = families(:empty)
    account = other.accounts.create!(name: "Other family brokerage", balance: 0, currency: "USD", accountable: Investment.new)
    Holding.create!(account: account, security: other_family_security, date: Date.current, qty: 5, price: 10, amount: 50, currency: "USD")

    get research_ticker_path("ZZUD")

    assert_response :success
    assert_select "h2", text: "Equity positions & cost basis", count: 0
    assert_no_match(/Other family brokerage/, response.body)
  end

  test "a held ticker still shows positions" do
    held = @user.accessible_accounts.flat_map { |a| a.current_holdings.to_a }.first
    skip "no held security in fixtures" unless held

    get research_ticker_path(held.security.ticker)

    assert_response :success
    assert_select "h2", text: "Equity positions & cost basis"
    assert_select "[data-testid=market-snapshot]", count: 0
  end

  test "an unknown ticker is looked up in the background and shows a pending page once" do
    assert_enqueued_with(job: TickerResearchGenerateJob, args: [ "QQZZ" ]) do
      get research_ticker_path("qqzz")
    end

    assert_response :accepted
    assert_select "[data-testid=ticker-pending]"

    assert_no_enqueued_jobs(only: TickerResearchGenerateJob) { get research_ticker_path("QQZZ") }
    assert_response :accepted
  end

  test "garbage and known-missing tickers are a plain 404 and queue nothing" do
    assert_no_enqueued_jobs(only: TickerResearchGenerateJob) do
      get research_ticker_path("not-a-ticker!!")
      assert_response :not_found

      Rails.cache.write(TickerResearchGenerateJob.missing_key("NOPE"), true)
      get research_ticker_path("NOPE")
      assert_response :not_found
    end
  end

  test "search finds unheld tickers by symbol or name and opens unknown uppercase tickers directly" do
    research_only!("ZZUE", name: "Zeta Unheld Energy")

    get research_search_path(q: "zeta")
    assert_response :success
    assert_select "[data-testid=other-tickers] a", text: "ZZUE"

    get research_search_path(q: "QQZY")
    assert_redirected_to research_ticker_path("QQZY")
  end

  test "a placeholder for a ticker you hold is not listed again under other tickers" do
    held = @user.accessible_accounts.flat_map { |a| a.current_holdings.to_a }.first
    skip "no held security in fixtures" unless held

    Security.create!(ticker: held.security.ticker, exchange_operating_mic: "XZZZ", offline: true, offline_reason: Security::RESEARCH_ONLY_REASON)

    # A partial match, since the exact ticker now jumps straight to its page
    get research_search_path(q: held.security.ticker.downcase[0..-2])

    assert_response :success
    assert_select "[data-testid=other-tickers] a", text: held.security.ticker, count: 0
  end

  test "an exact ticker in search opens its page, case-insensitively, held or not" do
    research_only!("ZZUG")

    get research_search_path(q: "zzug")
    assert_redirected_to research_ticker_path("ZZUG")

    get research_search_path(q: "  $zzug ")
    assert_redirected_to research_ticker_path("ZZUG")
  end

  test "a dollar-prefixed ticker we have never seen opens its page and queues the lookup" do
    get research_search_path(q: "$qqzx")
    assert_redirected_to research_ticker_path("QQZX")

    assert_enqueued_with(job: TickerResearchGenerateJob, args: [ "QQZX" ]) { get research_ticker_path("QQZX") }
  end

  test "a bare valid ticker opens its workspace and queues an unknown symbol without a second click" do
    get research_search_path(q: "QQZW")

    assert_redirected_to research_ticker_path("QQZW")
    assert_enqueued_with(job: TickerResearchGenerateJob, args: [ "QQZW" ]) { get research_ticker_path("QQZW") }
  end

  test "a company-name search with spaces remains a results search" do
    research_only!("ZZUH", name: "Quokka Industries")

    get research_search_path(q: "quokka industries")

    assert_response :success
    assert_select "[data-testid=other-tickers] a", text: "ZZUH"
  end

  test "search lists no unheld tickers without a query" do
    research_only!("ZZUF")

    get research_search_path

    assert_response :success
    assert_select "[data-testid=other-tickers]", count: 0
  end
end
