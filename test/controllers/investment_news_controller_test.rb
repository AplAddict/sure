require "test_helper"

class InvestmentNewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    @owner = users(:family_admin)
    @member = users(:family_member)
    @owned = @owner.family.accounts.create!(name: "News owner", balance: 100, cash_balance: 0, currency: "USD", owner: @owner, status: "active", accountable: Investment.new)
    @private = @owner.family.accounts.create!(name: "Private news", balance: 100, cash_balance: 0, currency: "USD", owner: @owner, status: "active", accountable: Investment.new)
    @own_security = Security.create!(ticker: "OWNNW", exchange_mic: "XNAS", name: "Owned News")
    secret_security = Security.create!(ticker: "SECNW", exchange_mic: "XNAS", name: "Secret News")
    @owned.holdings.create!(security: @own_security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD")
    @private.holdings.create!(security: secret_security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD")
    SecurityResearchSnapshot.create!(security: @own_security, status: "current", generated_at: Time.current, imported_at: Time.current, payload: { "news" => [ { "title" => "Owned headline", "link" => "https://example.com/owned", "source" => "Wire", "published" => "2026-10-12", "tickers" => [ "OWNNW" ] } ] })
    SecurityResearchSnapshot.create!(security: secret_security, status: "current", generated_at: Time.current, imported_at: Time.current, payload: { "news" => [ { "title" => "Private headline", "link" => "https://example.com/private", "source" => "Wire", "published" => "2026-10-12", "tickers" => [ "SECNW" ] } ] })
  end

  test "canonical news route applies account period sort filter and density settings" do
    sign_in @owner

    get research_news_path(scope: "account", account_id: @owned.id, period: "all", sort: "oldest", filter: "all", density: "compact")

    assert_response :success
    assert_select "select[name=scope] option[selected][value=account]"
    assert_select "input[type=hidden][name=account_id][value=?]", @owned.id.to_s
    assert_select "select[name=period] option[selected][value=all]"
    assert_select "select[name=sort] option[selected][value=oldest]"
    assert_select "select[name=filter] option[selected][value=all]"
    assert_select "select[name=density] option[selected][value=compact]"
    assert_includes response.body, "Owned headline"
    assert_not_includes response.body, "Private headline"
    assert_select "a[href='https://example.com/owned'][rel='noopener noreferrer']"
  end

  test "all scope normalizes artifact news through the canonical loader" do
    sign_in @owner
    title = "Artifact canonical headline"
    source = "Artifact Wire"
    digest = Digest::SHA256.hexdigest([ source, title ].join("\u0000"))
    SecurityHeadlineAnalysis.create!(
      security: @own_security,
      status: "current",
      source_digest: Digest::SHA256.hexdigest("artifact-current"),
      analyzed_at: Time.current,
      payload: { "articleTones" => { digest => { "tone" => "bullish" } } }
    )

    Dir.mktmpdir do |directory|
      File.write(File.join(directory, ResearchController::NEWS_FILE), JSON.generate([
        {
          "title" => "  #{title}  ",
          "link" => "https://example.com/artifact",
          "source" => source,
          "description" => "<strong>Normalized detail</strong>",
          "category" => "market_news",
          "publishedAt" => "2026-10-12T12:00:00Z",
          "tickers" => [ @own_security.ticker.downcase ]
        }
      ]))
      previous_path = ENV["INVEST_RESEARCH_PATH"]
      ENV["INVEST_RESEARCH_PATH"] = directory
      begin
        get research_news_path(scope: "all", period: "all", filter: "sentiment", density: "detail")
      ensure
        ENV["INVEST_RESEARCH_PATH"] = previous_path
      end
    end

    assert_response :success
    assert_select "article" do |articles|
      article = articles.sole
      assert_includes article.text, title
      assert_includes article.text, "Normalized detail"
      assert_includes article.text, "Market news"
      assert_includes article.text, I18n.t("pages.dashboard.settings.options.sentiment.bullish")
      assert_select article, "a[href='https://example.com/artifact'][rel='noopener noreferrer']"
    end
  end

  test "legacy portfolio news redirects to the canonical sentiment-rich research feed" do
    sign_in @owner

    get investment_news_path

    assert_redirected_to research_news_path
  end

end
