# Cached news for securities held in accounts the current member can access.
# It never reads the raw global artifact or another member's positions; it uses
# the imported per-security snapshots already shown elsewhere in Sure.
class InvestmentNews
  Article = Data.define(:title, :url, :source, :published_at, :published_raw, :tickers)

  attr_reader :user

  def initialize(user:)
    @user = user
  end

  def articles(limit: 40)
    snapshots.flat_map do |snapshot|
      Array(snapshot.section("news")).filter_map do |raw|
        title = raw["title"].to_s.squish
        published = (raw["published"] || raw["published_at"] || raw["publishedAt"] || raw["time"]).to_s.squish.presence
        url = raw["link"].to_s
        next unless title.present? && url.start_with?("https://")

        Article.new(
          title: title,
          url: url,
          source: raw["source"].to_s.squish.presence || "Source unavailable",
          published_at: parse_time(published),
          published_raw: published,
          tickers: Array(raw["tickers"]).map { |ticker| ticker.to_s.upcase }.uniq
        )
      end
    end.uniq(&:url).sort_by { |article| article.published_at ? -article.published_at.to_f : Float::INFINITY }.first(limit)
  end

  private
    # The feed mixes RFC 2822 ("Mon, 12 Oct 2026 13:29:00 +0000"), ISO 8601 and
    # bare dates. An unreadable value stays nil rather than becoming a guess.
    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError, RangeError
      nil
    end

    def snapshots
      security_ids = Holding.where(account_id: user.accessible_accounts.visible.select(:id)).select(:security_id).distinct
      SecurityResearchSnapshot.where(security_id: security_ids, status: "current").includes(:security)
    end
end
