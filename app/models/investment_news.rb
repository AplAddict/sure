# Backwards-compatible adapter for callers that still expect attribute-style
# articles. ResearchNews owns snapshot selection, parsing, normalization,
# deduplication, and ordering.
class InvestmentNews
  Article = Data.define(:title, :url, :source, :published_at, :published_raw, :tickers)

  def initialize(user:, source_unavailable: I18n.t("research.news.source_unavailable"))
    @research_news = ResearchNews.new(user: user, source_unavailable: source_unavailable)
  end

  def articles(limit: 40)
    research_news.rows.first(limit).map do |row|
      Article.new(**row.slice(*Article.members))
    end
  end

  private
    attr_reader :research_news
end
