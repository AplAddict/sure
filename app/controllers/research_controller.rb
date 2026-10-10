class ResearchController < ApplicationController
  RESEARCH_ROOT = Pathname.new(ENV.fetch("INVEST_RESEARCH_PATH", "/run/invest-research"))
  HEATMAP_FILE = "finviz_snapshot.json".freeze

  def search
    @query = params[:q].to_s.strip
    @securities = scoped_securities
    @securities = @securities.where("LOWER(securities.ticker) LIKE :q OR LOWER(securities.name) LIKE :q", q: "%#{@query.downcase}%") if @query.present?
    @securities = @securities.order(:ticker).limit(30)
    @articles = article_rows.select { |article| @query.blank? || article[:title].downcase.include?(@query.downcase) || article[:source].downcase.include?(@query.downcase) || article[:tickers].any? { |ticker| ticker.downcase.include?(@query.downcase) } }.first(30)
  end

  def news
    @articles = article_rows
  end

  def heatmap
    artifact = RESEARCH_ROOT.join(HEATMAP_FILE)
    @heatmap = if artifact.file?
      JSON.parse(artifact.read)
    end
  rescue JSON::ParserError
    @heatmap = nil
  end

  private
    def scoped_securities
      Security.where(id: Holding.where(account_id: accessible_accounts.select(:id)).select(:security_id).distinct)
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
