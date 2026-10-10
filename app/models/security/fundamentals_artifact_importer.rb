# Imports a static, generated fundamentals artifact from the read-only Invest
# research mount. It writes only Sure's existing display-only fundamentals cache.
class Security::FundamentalsArtifactImporter
  ROOT = Pathname.new(ENV.fetch("INVEST_RESEARCH_PATH", "/run/invest-research"))
  FILE = "sure_fundamentals.json".freeze

  def import_all(securities: Security::FundamentalsRefresher.held_securities)
    artifact = JSON.parse(ROOT.join(FILE).read)
    generated_at = Time.zone.parse(artifact.fetch("generatedAt"))
    securities.count { |security| import(security, artifact.fetch("symbols", {}), generated_at) }
  rescue Errno::ENOENT, JSON::ParserError, KeyError, ArgumentError
    0
  end

  def import(security, symbols, generated_at)
    source = symbols[security.ticker.to_s.upcase]
    return false unless source.is_a?(Hash) && source["error"].blank?

    SecurityFundamental.find_or_initialize_by(security: security).update!(
      payload: normalize(source), fetched_at: generated_at, last_attempt_at: Time.current,
      last_error: nil
    )
    true
  end

  private
    def normalize(source)
      {
        "currency" => source["currency"], "market_cap" => source["marketCap"],
        "trailing_pe" => source["trailingPE"], "forward_pe" => source["forwardPE"], "beta" => source["beta"],
        "dividend_yield" => percent(source["dividendYield"]), "dividend_rate" => source["dividendRate"],
        "payout_ratio" => percent(source["payoutRatio"]), "ex_dividend_date" => source["exDividendDate"],
        "fifty_two_week_high" => source["fiftyTwoWeekHigh"], "fifty_two_week_low" => source["fiftyTwoWeekLow"],
        "profit_margin" => percent(source["profitMargins"]), "operating_margin" => percent(source["operatingMargins"]),
        "revenue_growth" => percent(source["revenueGrowth"]), "earnings_growth" => percent(source["earningsGrowth"]),
        "return_on_equity" => percent(source["returnOnEquity"]), "recommendation" => source["recommendationKey"],
        "target_mean_price" => source["targetMeanPrice"], "analyst_count" => source["numberOfAnalystOpinions"],
        "strong_buy" => source["strongBuy"], "buy" => source["buy"], "hold" => source["hold"], "sell" => source["sell"], "strong_sell" => source["strongSell"],
        "next_earnings_date" => Array(source["earningsDate"]).first
      }.compact
    end

    def percent(value)
      value.nil? ? nil : value.to_d / 100
    end
end
