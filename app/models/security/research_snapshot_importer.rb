# Imports only static, generated Invest research artifacts from a read-only
# mount.  No Invest UI/API session, broker records, price data, or trade action
# crosses this boundary.
class Security::ResearchSnapshotImporter
  ROOT = Pathname.new(ENV.fetch("INVEST_RESEARCH_PATH", "/run/invest-research"))
  FILES = %w[quiver_research.json finviz_on_demand.json ticker_analysis.json ticker_reports.json news.json].freeze

  Result = Data.define(:imported, :unavailable, :invalid)

  def initialize(root: ROOT, now: Time.current)
    @root = Pathname.new(root)
    @now = now
  end

  def import_all(securities: Security::FundamentalsRefresher.held_securities)
    artifacts = load_artifacts
    unless artifacts
      securities.each { |security| import(security, artifacts: nil) }
      return Result.new(imported: 0, unavailable: securities.size, invalid: 0)
    end

    imported = invalid = 0
    securities.each do |security|
      outcome = import(security, artifacts: artifacts)
      imported += 1 if outcome == :imported
      invalid += 1 if outcome == :invalid
    end
    Result.new(imported: imported, unavailable: securities.size - imported - invalid, invalid: invalid)
  end

  def import(security, artifacts: load_artifacts)
    record = SecurityResearchSnapshot.find_or_initialize_by(security: security)
    unless artifacts
      record.update!(status: "unavailable", last_error: "Research artifacts are not mounted", imported_at: @now)
      return :unavailable
    end

    symbol = security.ticker.to_s.upcase
    payload = build_payload(symbol, artifacts)
    if payload.values.all? { |value| value.blank? }
      record.update!(payload: {}, status: "unavailable", imported_at: @now, generated_at: artifacts.fetch(:generated_at), last_error: nil)
      return :unavailable
    end

    record.update!(payload: payload, status: freshness(artifacts.fetch(:generated_at)), generated_at: artifacts.fetch(:generated_at), imported_at: @now, last_error: nil)
    :imported
  rescue JSON::ParserError => e
    record ||= SecurityResearchSnapshot.find_or_initialize_by(security: security)
    record.update!(status: "invalid", last_error: "Invalid research artifact: #{e.message.truncate(120)}", imported_at: @now)
    :invalid
  end

  private

  def load_artifacts
    return nil unless FILES.all? { |name| @root.join(name).file? }
    raw = FILES.index_with { |name| JSON.parse(@root.join(name).read) }
    generated = [raw["quiver_research.json"].fetch("generatedAt", nil), File.mtime(@root.join("news.json"))]
                  .filter_map { |value| value.is_a?(Time) ? value : Time.zone.parse(value.to_s) rescue nil }.max
    { quiver: raw["quiver_research.json"], finviz: raw["finviz_on_demand.json"], analysis: raw["ticker_analysis.json"], reports: raw["ticker_reports.json"], news: raw["news.json"], generated_at: generated || @now }
  end

  def build_payload(symbol, artifacts)
    articles = Array(artifacts[:news]).select { |article| Array(article["tickers"]).map(&:upcase).include?(symbol) }.first(8)
    {
      "quiver" => artifacts[:quiver].dig("symbols", symbol),
      "finviz" => artifacts[:finviz].dig("symbols", symbol),
      "analysis" => artifacts[:analysis][symbol],
      "reports" => artifacts[:reports][symbol],
      "news" => articles
    }.compact
  end

  def freshness(generated_at)
    generated_at < SecurityResearchSnapshot::STALE_AFTER.ago ? "stale" : "current"
  end
end
