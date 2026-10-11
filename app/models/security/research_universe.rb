# Makes every ticker we have research for browsable, whether or not anyone
# holds it. Each one becomes an offline "research only" security: it gets a page
# and cached stock data, but no prices, no health checks and no sync work.
#
# Sources are the same read-only artifacts the snapshot importer reads. A ticker
# that appears in any of them (the liquid-equity scan, Quiver, Finviz, analysis,
# reports or news tags) gets a row.
class Security::ResearchUniverse
  SYMBOL = Security::FundamentalsRefresher::YAHOO_SYMBOL
  UNIVERSE_FILE = "liquid_equity_universe_scan.json".freeze
  SYMBOL_MAPS = %w[quiver_research.json finviz_on_demand.json].freeze
  SYMBOL_KEYED = %w[ticker_analysis.json ticker_reports.json].freeze

  def initialize(root: Security::ResearchSnapshotImporter::ROOT)
    @root = Pathname.new(root)
  end

  # Returns the number of securities created.
  def seed
    known = Security.pluck(:ticker).map { |ticker| ticker.to_s.upcase }.to_set
    created = 0

    entries.each do |symbol, attrs|
      next if known.include?(symbol)

      Security.create!(
        ticker: symbol,
        name: attrs[:name],
        sector: attrs[:sector],
        kind: "standard",
        country_code: "US",
        offline: true,
        offline_reason: Security::RESEARCH_ONLY_REASON
      )
      known << symbol
      created += 1
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[ResearchUniverse] skipped #{symbol}: #{e.message.truncate(120)}")
    end

    created
  end

  def entries
    result = {}

    Array(read(UNIVERSE_FILE)&.dig("tickers")).each do |row|
      symbol = row["symbol"].to_s.upcase
      next unless symbol.match?(SYMBOL)

      result[symbol] = { name: row["name"].presence, sector: row["sector"].presence }
    end

    extra_symbols.each { |symbol| result[symbol] ||= { name: nil, sector: nil } }
    result
  end

  private
    def extra_symbols
      symbols = []
      SYMBOL_MAPS.each { |file| symbols.concat(read(file)&.dig("symbols")&.keys.to_a) }
      SYMBOL_KEYED.each { |file| symbols.concat(read(file)&.keys.to_a) }
      Array(read("news.json")).each { |article| symbols.concat(Array(article["tickers"])) }

      symbols.map { |symbol| symbol.to_s.upcase }.select { |symbol| symbol.match?(SYMBOL) }.uniq
    end

    def read(name)
      path = @root.join(name)
      path.file? ? JSON.parse(path.read) : nil
    rescue JSON::ParserError
      nil
    end
end
