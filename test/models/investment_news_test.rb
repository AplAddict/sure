require "test_helper"

class InvestmentNewsTest < ActiveSupport::TestCase
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    @owner = users(:family_admin)
    account = @owner.family.accounts.create!(name: "News order", balance: 100, cash_balance: 0, currency: "USD", owner: @owner, status: "active", accountable: Investment.new)
    @security = Security.create!(ticker: "NWORD", exchange_mic: "XNAS", name: "News Order")
    account.holdings.create!(security: @security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD")
  end

  def news(*items)
    SecurityResearchSnapshot.create!(security: @security, status: "current", generated_at: Time.current, imported_at: Time.current,
                                     payload: { "news" => items.each_with_index.map { |published, i| { "title" => "Story #{i}", "link" => "https://example.com/#{i}", "source" => "Wire", "published" => published, "tickers" => [ "NWORD" ] } } })
    InvestmentNews.new(user: @owner).articles
  end

  test "delegates canonical loading and only adapts the legacy article shape" do
    published_at = Time.zone.parse("2026-10-12T13:29:00Z")
    canonical = {
      title: "Canonical", url: "https://example.com/canonical", source: "Wire",
      published_at: published_at, published_raw: "2026-10-12T13:29:00Z", tickers: [ "NWORD" ],
      description: "Detail", category: "markets", security_id: @security.id.to_s, headline_sentiments: []
    }
    ResearchNews.any_instance.expects(:rows).once.returns([ canonical ])

    article = InvestmentNews.new(user: @owner).articles.sole

    assert_equal canonical.slice(*InvestmentNews::Article.members), article.to_h
  end

  test "uses the localized canonical missing-source label" do
    SecurityResearchSnapshot.create!(
      security: @security, status: "current", generated_at: Time.current, imported_at: Time.current,
      payload: { "news" => [ { "title" => "No source", "link" => "https://example.com/no-source" } ] }
    )

    article = InvestmentNews.new(user: @owner).articles.sole

    assert_equal I18n.t("research.news.source_unavailable"), article.source
  end

  test "orders by real time across the feed's mixed date formats, not alphabetically" do
    articles = news("Wed, 07 Oct 2026 18:43:07 +0000", "Mon, 12 Oct 2026 13:29:00 +0000", "2026-10-09T00:00:00+00:00")

    assert_equal [ "Story 1", "Story 2", "Story 0" ], articles.map(&:title)
  end

  test "parses each format to a time" do
    articles = news("Mon, 12 Oct 2026 13:29:00 +0000", "2026-10-09T00:00:00+00:00", "2026-10-08")

    assert articles.all? { |a| a.published_at.respond_to?(:to_time) && !a.published_at.is_a?(String) }
    assert_equal Time.utc(2026, 10, 12, 13, 29), articles.first.published_at.utc
  end

  test "an article with no usable date is listed last and keeps no invented time" do
    articles = news("not a date", "Mon, 12 Oct 2026 13:29:00 +0000", nil)

    assert_equal "Story 1", articles.first.title
    assert_nil articles.last.published_at
    assert_nil articles[-2].published_at
  end

  test "a date-only value is treated as a day, and its raw text is kept for display" do
    article = news("2026-10-08").first

    assert_equal Date.new(2026, 10, 8), article.published_at.to_date
    assert_equal "2026-10-08", article.published_raw
  end
end
