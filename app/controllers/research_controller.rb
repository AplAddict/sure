class ResearchController < ApplicationController
  NEWS_FILE = "news.json".freeze
  PAGE_SIZE = 40

  def search
    @query = params[:q].to_s.strip
    @securities = scoped_securities
    @securities = @securities.where("LOWER(securities.ticker) LIKE :q OR LOWER(securities.name) LIKE :q", q: "%#{@query.downcase}%") if @query.present?
    @securities = @securities.order(:ticker).limit(30)
    @articles = article_rows.select { |article| @query.blank? || article[:title].downcase.include?(@query.downcase) || article[:source].downcase.include?(@query.downcase) || article[:tickers].any? { |ticker| ticker.downcase.include?(@query.downcase) } }.first(30)
  end

  def news
    @scope = %w[portfolio all].include?(params[:scope]) ? params[:scope] : "portfolio"
    @query = params[:q].to_s.strip
    @source = params[:source].to_s.strip
    @category = params[:category].to_s.strip
    @ticker = params[:ticker].to_s.upcase.strip
    @sort = %w[latest title].include?(params[:sort]) ? params[:sort] : "latest"
    @page = [params[:page].to_i, 1].max
    @all_articles = news_rows
    @sources = @all_articles.map { |article| article[:source] }.uniq.sort
    @categories = @all_articles.map { |article| article[:category] }.compact.uniq.sort
    @articles = filter_news(@all_articles)
    @articles = @articles.sort_by { |article| @sort == "title" ? article[:title].downcase : article[:published_at].to_s }.reverse
    @total = @articles.size
    @articles = @articles.drop((@page - 1) * PAGE_SIZE).first(PAGE_SIZE)
  end

  def ticker
    @ticker = params[:ticker].to_s.upcase.strip
    @holdings = accessible_accounts.flat_map do |account|
      account.current_holdings.joins(:security).where(securities: { ticker: @ticker }).includes(:security).to_a
    end
    raise ActiveRecord::RecordNotFound if @holdings.empty?

    @security = @holdings.first.security
  end

  private
    def scoped_securities
      Security.where(id: Holding.where(account_id: accessible_accounts.select(:id)).select(:security_id).distinct)
    end

    def news_rows
      artifact = Pathname.new(ENV.fetch("INVEST_RESEARCH_PATH", "/run/invest-research")).join(NEWS_FILE)
      Array(JSON.parse(artifact.read)).filter_map do |article|
        next unless article["title"].present? && article["link"].to_s.start_with?("https://")
        { title: article["title"], url: article["link"], description: article["description"].to_s.gsub(/<[^>]*>/, " ").squish, source: article["source"].presence || "Source unavailable", category: article["category"].presence, published_at: article["published"] || article["published_at"] || article["publishedAt"] || article["time"], tickers: Array(article["tickers"]).map(&:to_s).map(&:upcase) }
      end.uniq { |article| article[:url] }
    rescue Errno::ENOENT, JSON::ParserError
      []
    end

    def filter_news(rows)
      held = scoped_securities.pluck(:ticker).map(&:upcase).to_set
      rows.select do |article|
        text = [article[:title], article[:description], article[:source], article[:category], article[:tickers].join(" ")].join(" ").downcase
        (@scope == "all" || (article[:tickers] & held.to_a).any?) &&
          (@query.blank? || text.include?(@query.downcase)) &&
          (@source.blank? || article[:source] == @source) &&
          (@category.blank? || article[:category] == @category) &&
          (@ticker.blank? || article[:tickers].include?(@ticker))
      end
    end

    def article_rows
      security_ids = scoped_securities.select(:id)
      SecurityResearchSnapshot.where(security_id: security_ids).filter_map do |snapshot|
        Array(snapshot.section("news")).filter_map do |article|
          next unless article["title"].present? && article["link"].to_s.start_with?("https://")
          { title: article["title"], url: article["link"], source: article["source"].presence || "Source unavailable", published_at: article["published_at"] || article["publishedAt"] || article["time"], tickers: Array(article["tickers"]).map(&:to_s).map(&:upcase) }
        end
      end.flatten.uniq { |article| article[:url] }.sort_by { |article| article[:published_at].to_s }.reverse
    end
end
