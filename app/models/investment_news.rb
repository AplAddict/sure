# Cached news for securities held in accounts the current member can access.
# It never reads the raw global artifact or another member's positions; it uses
# the imported per-security snapshots already shown elsewhere in Sure.
class InvestmentNews
  Article = Data.define(:title, :url, :source, :published_at, :tickers)

  attr_reader :user

  def initialize(user:)
    @user = user
  end

  def articles(limit: 40)
    snapshots.flat_map do |snapshot|
      Array(snapshot.section("news")).filter_map do |raw|
        title = raw["title"].to_s.squish
        url = raw["link"].to_s
        next unless title.present? && url.start_with?("https://")

        Article.new(
          title: title,
          url: url,
          source: raw["source"].to_s.squish.presence || "Source unavailable",
          published_at: raw["published"] || raw["published_at"] || raw["publishedAt"] || raw["time"],
          tickers: Array(raw["tickers"]).map { |ticker| ticker.to_s.upcase }.uniq
        )
      end
    end.uniq(&:url).sort_by { |article| article.published_at.to_s }.reverse.first(limit)
  end

  private
    def snapshots
      security_ids = Holding.where(account_id: user.accessible_accounts.visible.select(:id)).select(:security_id).distinct
      SecurityResearchSnapshot.where(security_id: security_ids, status: "current").includes(:security)
    end
end
