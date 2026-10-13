class ResearchNews
  def initialize(user:, source_unavailable:)
    @user = user
    @source_unavailable = source_unavailable
  end

  # Persisted news is fail-closed: only the snapshot explicitly marked current
  # can contribute rows. Superseded, stale, invalid, and unavailable snapshots
  # remain available for diagnostics but never surface as current news.
  def rows
    normalized_rows(
      current_snapshots.where(security_id: securities.select(:id)).flat_map do |snapshot|
        rows_from_snapshot(snapshot)
      end
    )
  end

  def rows_for(security:)
    snapshot = current_snapshots.find_by(security: security)
    normalized_rows(snapshot ? rows_from_snapshot(snapshot) : [])
  end

  # Normalizes article hashes from trusted local artifacts through the same
  # field and sentiment contract as persisted research snapshots. Artifact rows
  # do not have a canonical Security association, so security_id remains nil and
  # their ticker list comes only from the input payload.
  def rows_from(articles)
    normalized_rows(Array(articles).filter_map { |article| build_row(article) })
  end

  private
    attr_reader :user, :source_unavailable

    def securities
      @securities ||= begin
        held = Holding.where(account_id: user.accessible_accounts.visible.select(:id)).select(:security_id)
        watched = user.research_watchlist_entries.active.select(:security_id)
        Security.where(id: held).or(Security.where(id: watched))
      end
    end

    def current_snapshots
      SecurityResearchSnapshot.where(status: "current").includes(:security)
    end

    def rows_from_snapshot(snapshot)
      Array(snapshot.section("news")).filter_map do |article|
        build_row(article, security: snapshot.security)
      end
    end

    def build_row(article, security: nil)
      return unless article.is_a?(Hash)

      title = article["title"].to_s.squish
      return unless title.present? && article["link"].to_s.start_with?("https://")

      raw_source = article["source"].to_s.squish
      published_raw = (article["published"] || article["published_at"] || article["publishedAt"] || article["time"]).to_s.squish.presence
      tickers = Array(article["tickers"]).map(&:to_s).map(&:upcase).uniq
      tickers |= [ security.ticker ] if security
      {
        title: title,
        url: article["link"],
        description: article["description"].to_s.gsub(/<[^>]*>/, " ").squish,
        source: raw_source.presence || source_unavailable,
        category: article["category"].presence,
        published_at: published_at(published_raw),
        published_raw: published_raw,
        security_id: security&.id&.to_s,
        tickers: tickers,
        headline_sentiments: headline_sentiments(raw_source, title)
      }
    end

    def normalized_rows(rows)
      rows.uniq { |article| article[:url] }.sort_by { |article| article[:published_at].to_s }.reverse
    end

    def published_at(value)
      return value.in_time_zone if value.respond_to?(:in_time_zone)

      Time.zone.parse(value.to_s) if value.present?
    rescue ArgumentError, TypeError
      nil
    end

    def headline_sentiments(source, title)
      key = Digest::SHA256.hexdigest([ source.to_s.squish, title.to_s.squish.truncate(Security::HeadlineToneAnalyzer::TITLE_LIMIT) ].join("\u0000"))
      headline_sentiment_index.fetch(key, [])
    end

    def headline_sentiment_index
      @headline_sentiment_index ||= SecurityHeadlineAnalysis.includes(:security)
        .where(security_id: securities.select(:id), status: "current")
        .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |analysis, index|
          analysis.payload.fetch("articleTones", {}).each do |article_key, result|
            tone = result["tone"].to_s
            next unless Security::HeadlineToneAnalyzer::TONES.include?(tone)

            label = { ticker: analysis.security.ticker, tone: tone }
            index[article_key] << label unless index[article_key].include?(label)
          end
        end
    end
end
