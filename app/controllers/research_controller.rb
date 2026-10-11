class ResearchController < ApplicationController
  NEWS_FILE = "news.json".freeze
  PAGE_SIZE = 40

  def search
    @query = params[:q].to_s.strip
    @securities = scoped_securities
    @securities = @securities.where("LOWER(securities.ticker) LIKE :q OR LOWER(securities.name) LIKE :q", q: "%#{@query.downcase}%") if @query.present?
    @securities = @securities.order(:ticker).limit(30)

    # Every other ticker with a research page. Only searched, never listed in
    # full, so the page stays short; securities are shared market reference data,
    # not family data.
    @other_securities = if @query.present?
      Security.research_only.where.not(id: scoped_securities.select(:id))
              .where.not("UPPER(securities.ticker) IN (?)", scoped_securities.pluck(:ticker).map(&:upcase).presence || [ "" ])
              .where("LOWER(securities.ticker) LIKE :q OR LOWER(securities.name) LIKE :q", q: "%#{@query.downcase}%")
              .order(Arel.sql("CASE WHEN UPPER(securities.ticker) = #{Security.connection.quote(@query.upcase)} THEN 0 ELSE 1 END"), :ticker).limit(30)
    else
      Security.none
    end
    @lookup_ticker = @query.upcase if @query.match?(Security::FundamentalsRefresher::YAHOO_SYMBOL) &&
                                      @securities.none? { |s| s.ticker.casecmp?(@query) } && @other_securities.none? { |s| s.ticker.casecmp?(@query) }
    @articles = article_rows.select { |article| @query.blank? || article[:title].downcase.include?(@query.downcase) || article[:source].downcase.include?(@query.downcase) || article[:tickers].any? { |ticker| ticker.downcase.include?(@query.downcase) } }.first(30)
  end

  def news
    @scope = %w[portfolio all].include?(params[:scope]) ? params[:scope] : "portfolio"
    @query = params[:q].to_s.strip
    @source = params[:source].to_s.strip
    @category = params[:category].to_s.strip
    @sentiment = Security::HeadlineToneAnalyzer::TONES.include?(params[:sentiment].to_s) ? params[:sentiment].to_s : ""
    @ticker = params[:ticker].to_s.upcase.strip
    @sort = %w[latest title].include?(params[:sort]) ? params[:sort] : "latest"
    @page = [params[:page].to_i, 1].max
    @all_articles = @scope == "portfolio" ? article_rows : news_rows
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
    @security = @holdings.first&.security || find_research_security(@ticker)
    return render_pending_ticker unless @security

    @scan = @security.research_snapshot&.section("scan").presence
    @holding_currencies = @holdings.map(&:currency).uniq
    @aggregate_position = aggregate_ticker_position
    @purchase_entries = @holdings.flat_map(&:trades)
                                .select { |entry| entry.trade&.buy? }
                                .sort_by { |entry| [ entry.date || Date.new(1900, 1, 1), entry.id ] }
                                .reverse
    @option_positions = option_positions_for_ticker
  end

  private
    # Any known ticker has a page, held or not. A ticker we have never seen is
    # looked up in the background and its page appears on refresh; one the market
    # source says does not exist is a normal 404.
    def find_research_security(ticker)
      Security.where("UPPER(securities.ticker) = ?", ticker).order(:offline, :created_at).first
    end

    def render_pending_ticker
      raise ActiveRecord::RecordNotFound unless @ticker.match?(Security::FundamentalsRefresher::YAHOO_SYMBOL)
      raise ActiveRecord::RecordNotFound if Rails.cache.read(TickerResearchGenerateJob.missing_key(@ticker))

      if Rails.cache.write("research_ticker_pending:#{@ticker}", true, unless_exist: true, expires_in: 2.minutes)
        TickerResearchGenerateJob.perform_later(@ticker)
      end

      render :ticker_pending, status: :accepted
    end

    def aggregate_ticker_position
      return { available: false } unless @holding_currencies.one?

      currency = @holding_currencies.first
      quantity = @holdings.sum { |holding| holding.qty.to_d }
      market_value = @holdings.sum { |holding| holding.amount.to_d }
      known_cost_holdings = @holdings.select { |holding| holding.cost_basis.present? && holding.qty.positive? }
      complete_cost_basis = known_cost_holdings.size == @holdings.size
      book_value = complete_cost_basis ? known_cost_holdings.sum { |holding| holding.cost_basis.to_d * holding.qty.to_d } : nil

      {
        available: true,
        currency: currency,
        quantity: quantity,
        market_value: market_value,
        book_value: book_value,
        gain_loss: book_value ? market_value - book_value : nil,
        covered_accounts: known_cost_holdings.size,
        account_count: @holdings.size
      }
    end

    # Contract positions are rendered from a read-only provider snapshot and
    # deliberately excluded from the equity positions, totals, and net-worth
    # calculations above. SnapTrade gives us an OCC-style contract symbol, so
    # match only contracts beginning with this exact ticker and a space.
    def option_positions_for_ticker
      account_ids = accessible_accounts.pluck(:id).to_set

      SnaptradeAccount.includes(:account_provider).filter_map do |provider_account|
        account = provider_account.current_account
        next unless account && account_ids.include?(account.id)

        Array(provider_account.raw_options_payload).filter_map do |raw_position|
          position = raw_position.to_h.with_indifferent_access
          instrument = position[:instrument].to_h.with_indifferent_access
          contract = instrument[:symbol].to_s
          next unless contract.match?(/\A#{Regexp.escape(@ticker)}\s/)

          expiration = Date.iso8601(instrument[:expiration_date].to_s) rescue nil
          currency = position[:currency].is_a?(Hash) ? position[:currency].with_indifferent_access[:code] : position[:currency]

          {
            account: account,
            contract: contract,
            type: instrument[:option_type].presence || "Unavailable",
            expiration: expiration,
            strike: decimal_or_nil(instrument[:strike_price]),
            quantity: decimal_or_nil(position[:units]),
            mark: decimal_or_nil(position[:price]),
            currency: currency.presence || account.currency
          }
        end
      end.flatten
    end

    def decimal_or_nil(value)
      value.present? ? BigDecimal(value.to_s) : nil
    rescue ArgumentError
      nil
    end

    def scoped_securities
      Security.where(id: Holding.where(account_id: accessible_accounts.select(:id)).select(:security_id).distinct)
    end

    def news_rows
      artifact = Pathname.new(ENV.fetch("INVEST_RESEARCH_PATH", "/run/invest-research")).join(NEWS_FILE)
      Array(JSON.parse(artifact.read)).filter_map do |article|
        title = article["title"].to_s.squish
        next unless title.present? && article["link"].to_s.start_with?("https://")

        raw_source = article["source"].to_s.squish
        { title: title, url: article["link"], description: article["description"].to_s.gsub(/<[^>]*>/, " ").squish, source: raw_source.presence || "Source unavailable", category: article["category"].presence, published_at: article["published"] || article["published_at"] || article["publishedAt"] || article["time"], tickers: Array(article["tickers"]).map(&:to_s).map(&:upcase), headline_sentiments: headline_sentiments_for(raw_source, title) }
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
          (@sentiment.blank? || article[:headline_sentiments].any? { |sentiment| sentiment[:tone] == @sentiment }) &&
          (@ticker.blank? || article[:tickers].include?(@ticker))
      end
    end

    def article_rows
      security_ids = scoped_securities.select(:id)
      SecurityResearchSnapshot.where(security_id: security_ids).filter_map do |snapshot|
        Array(snapshot.section("news")).filter_map do |article|
          title = article["title"].to_s.squish
          next unless title.present? && article["link"].to_s.start_with?("https://")

          raw_source = article["source"].to_s.squish
          { title: title, url: article["link"], source: raw_source.presence || "Source unavailable", published_at: article["published"] || article["published_at"] || article["publishedAt"] || article["time"], tickers: Array(article["tickers"]).map(&:to_s).map(&:upcase), headline_sentiments: headline_sentiments_for(raw_source, title) }
        end
      end.flatten.uniq { |article| article[:url] }.sort_by { |article| article[:published_at].to_s }.reverse
    end

    # Jev sentiment remains research-only and is scoped to securities the
    # signed-in user can access. The persisted cache stores article digests,
    # not raw headlines, so UI rows recompute the same digest for lookup.
    def headline_sentiments_for(source, title)
      key = Digest::SHA256.hexdigest([source.to_s.squish, title.to_s.squish.truncate(Security::HeadlineToneAnalyzer::TITLE_LIMIT)].join("\u0000"))
      headline_sentiment_index.fetch(key, [])
    end

    def headline_sentiment_index
      @headline_sentiment_index ||= SecurityHeadlineAnalysis.includes(:security)
        .where(security_id: scoped_securities.select(:id), status: "current")
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
