class ResearchController < ApplicationController
  NEWS_FILE = "news.json".freeze
  PAGE_SIZE = 40

  def search
    @query = params[:q].to_s.strip
    if (target = direct_ticker_target)
      return redirect_to research_ticker_path(target)
    end

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
    candidate = @query.upcase
    @lookup_ticker = candidate if candidate.match?(Security::FundamentalsRefresher::YAHOO_SYMBOL) &&
                                  @securities.none? { |s| s.ticker.casecmp?(candidate) } && @other_securities.none? { |s| s.ticker.casecmp?(candidate) }
    @articles = article_rows.select { |article| @query.blank? || article[:title].downcase.include?(@query.downcase) || article[:source].downcase.include?(@query.downcase) || article[:tickers].any? { |ticker| ticker.downcase.include?(@query.downcase) } }.first(30)
  end

  def news
    @scope = %w[overall portfolio account security watchlist all].include?(params[:scope]) ? params[:scope] : "portfolio"
    @query = params[:q].to_s.strip
    @source = params[:source].to_s.strip
    @category = params[:category].to_s.strip
    @sentiment = Security::HeadlineToneAnalyzer::TONES.include?(params[:sentiment].to_s) ? params[:sentiment].to_s : ""
    @ticker = params[:ticker].to_s.upcase.strip
    @sort = %w[latest oldest title].include?(params[:sort]) ? params[:sort] : "latest"
    @period = %w[all 1m 3m ytd 1y].include?(params[:period]) ? params[:period] : "all"
    @filter = %w[all sentiment].include?(params[:filter]) ? params[:filter] : "all"
    @density = %w[compact detail].include?(params[:density]) ? params[:density] : "detail"
    @account_id = if @scope == "account"
      accessible_accounts.visible.where(accountable_type: %w[Investment Crypto]).find_by(id: params[:account_id])&.id&.to_s
    end
    @page = [params[:page].to_i, 1].max
    @all_articles = @scope == "all" ? news_rows : article_rows
    @sources = @all_articles.map { |article| article[:source] }.uniq.sort
    @categories = @all_articles.map { |article| article[:category] }.compact.uniq.sort
    @articles = filter_news(@all_articles)
    @articles = case @sort
    when "title" then @articles.sort_by { |article| article[:title].downcase }
    when "oldest" then @articles.sort_by { |article| article[:published_at] || Time.zone.at(0) }
    else @articles.sort_by { |article| article[:published_at] || Time.zone.at(0) }.reverse
    end
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

    @ticker_news = research_news.rows_for(security: @security)
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
    # A query that is exactly a ticker opens its dynamic workspace immediately.
    # Unknown symbols queue the on-demand lookup from that page. Company searches
    # containing whitespace remain result searches, so we do not reinterpret a
    # company name as a market symbol.
    def direct_ticker_target
      explicit = @query.start_with?("$")
      raw = @query.delete_prefix("$").strip
      return if raw.match?(/\s/)

      symbol = raw.upcase
      return unless symbol.match?(Security::FundamentalsRefresher::YAHOO_SYMBOL)

      # Known symbols are direct regardless of case. For a symbol not in the
      # local universe, uppercase is the unambiguous bare-ticker form; `$foo`
      # remains available when a user intentionally wants an ambiguous symbol.
      symbol if explicit || raw == symbol || Security.where("UPPER(securities.ticker) = ?", symbol).exists?
    end

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
      SnaptradeAccount.linked_to(accessible_accounts.pluck(:id)).flat_map do |provider_account|
        account = provider_account.current_account
        provider_account.option_positions_snapshot.filter_map do |position|
          next unless position.underlying == @ticker

          {
            account: account,
            contract: position.contract,
            type: position.type || "Unavailable",
            expiration: position.expiration,
            strike: position.strike,
            quantity: position.quantity,
            mark: position.mark,
            currency: position.currency || account.currency
          }
        end
      end
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
      research_news.rows_from(JSON.parse(artifact.read))
    rescue Errno::ENOENT, JSON::ParserError
      []
    end

    def filter_news(rows)
      allowed_tickers = case @scope
      when "all"
        nil
      when "account"
        @account_id ? Security.where(id: Holding.where(account_id: @account_id).select(:security_id)).pluck(:ticker).map(&:upcase).to_set : Set.new
      when "watchlist"
        Security.where(id: Current.user.research_watchlist_entries.active.select(:security_id)).pluck(:ticker).map(&:upcase).to_set
      when "security"
        @ticker.present? ? [ @ticker ].to_set : Set.new
      when "overall"
        news_securities.pluck(:ticker).map(&:upcase).to_set
      else
        scoped_securities.pluck(:ticker).map(&:upcase).to_set
      end
      period = news_period

      rows.select do |article|
        text = [article[:title], article[:description], article[:source], article[:category], article[:tickers].join(" ")].join(" ").downcase
        (allowed_tickers.nil? || (article[:tickers] & allowed_tickers.to_a).any?) &&
          (@query.blank? || text.include?(@query.downcase)) &&
          (@source.blank? || article[:source] == @source) &&
          (@category.blank? || article[:category] == @category) &&
          (@filter != "sentiment" || article[:headline_sentiments].any?) &&
          (@sentiment.blank? || article[:headline_sentiments].any? { |sentiment| sentiment[:tone] == @sentiment }) &&
          (@ticker.blank? || article[:tickers].include?(@ticker)) &&
          (period.nil? || article[:published_at]&.to_date&.between?(period.start_date, period.end_date))
      end
    end

    def article_rows
      research_news.rows
    end

    def research_news
      @research_news ||= ResearchNews.new(user: Current.user, source_unavailable: t("research.news.source_unavailable"))
    end

    def news_securities
      held = Holding.where(account_id: accessible_accounts.visible.select(:id)).select(:security_id)
      watched = Current.user.research_watchlist_entries.active.select(:security_id)
      Security.where(id: held).or(Security.where(id: watched))
    end

    def news_period
      key = { "1m" => "last_30_days", "3m" => "last_90_days", "ytd" => "current_year", "1y" => "last_365_days" }[@period]
      Period.from_key(key) if key
    end
end
