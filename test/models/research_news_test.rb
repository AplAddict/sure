require "test_helper"

class ResearchNewsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @security = securities(:aapl)
    @title = "Canonical fixture headline"
    @source = "Fixture Wire"
    @digest = Digest::SHA256.hexdigest([ @source, @title ].join("\u0000"))
    @security.research_snapshot&.destroy!
    @security.headline_analysis&.destroy!
    @snapshot = SecurityResearchSnapshot.create!(
      security: @security,
      status: "current",
      generated_at: Time.current,
      imported_at: Time.current,
      payload: {
        "news" => [
          {
            "title" => @title,
            "link" => "https://example.com/canonical",
            "source" => @source,
            "description" => "<strong>Canonical detail</strong>",
            "category" => "markets",
            "published" => Time.current.iso8601,
            "tickers" => []
          }
        ]
      }
    )
  end

  test "loads canonical article fields and only current sentiment" do
    SecurityHeadlineAnalysis.create!(
      security: @security,
      status: "current",
      source_digest: Digest::SHA256.hexdigest("current"),
      analyzed_at: Time.current,
      payload: { "articleTones" => { @digest => { "tone" => "bullish" } } }
    )

    row = ResearchNews.new(user: @user, source_unavailable: "Unavailable").rows.sole

    assert_equal @title, row[:title]
    assert_equal "Canonical detail", row[:description]
    assert_equal "markets", row[:category]
    assert_equal @security.id.to_s, row[:security_id]
    assert_equal [ @security.ticker ], row[:tickers]
    assert_equal [ { ticker: @security.ticker, tone: "bullish" } ], row[:headline_sentiments]
  end

  test "artifact input has normalized parity without a security association" do
    SecurityHeadlineAnalysis.create!(
      security: @security,
      status: "current",
      source_digest: Digest::SHA256.hexdigest("current"),
      analyzed_at: Time.current,
      payload: { "articleTones" => { @digest => { "tone" => "bullish" } } }
    )
    loader = ResearchNews.new(user: @user, source_unavailable: "Unavailable")
    database_row = loader.rows.sole
    artifact_row = loader.rows_from([
      {
        "title" => "  #{@title}  ",
        "link" => "https://example.com/canonical",
        "source" => @source,
        "description" => "<strong>Canonical detail</strong>",
        "category" => "markets",
        "published" => database_row.fetch(:published_at).iso8601,
        "tickers" => [ @security.ticker.downcase ]
      }
    ]).sole

    assert_equal database_row.keys, artifact_row.keys
    assert_nil artifact_row[:security_id]
    assert_equal database_row.except(:security_id), artifact_row.except(:security_id)
  end

  test "does not surface a non-current persisted snapshot" do
    @snapshot.update!(status: "stale")
    loader = ResearchNews.new(user: @user, source_unavailable: "Unavailable")

    assert_empty loader.rows
    assert_empty loader.rows_for(security: @security)
  end

  test "does not expose stale sentiment" do
    SecurityHeadlineAnalysis.create!(
      security: @security,
      status: "stale",
      source_digest: Digest::SHA256.hexdigest("stale"),
      analyzed_at: 2.days.ago,
      payload: { "articleTones" => { @digest => { "tone" => "bearish" } } }
    )

    loader = ResearchNews.new(user: @user, source_unavailable: "Unavailable")
    assert_empty loader.rows.sole[:headline_sentiments]
    assert_empty loader.rows_from([
      { "title" => @title, "link" => "https://example.com/stale", "source" => @source }
    ]).sole[:headline_sentiments]
  end
end
