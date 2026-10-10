# Runs bounded typed Jev analysis over the already-imported ticker news snapshot.
# Only fixed labels are persisted; article content never leaves the research snapshot.
class Security::HeadlineToneAnalyzer
  TONES = %w[bullish neutral bearish mixed insufficient_evidence].freeze
  COVERAGE = %w[qualified partial insufficient].freeze
  MAX_ARTICLES = 8
  TITLE_LIMIT = 240
  DESCRIPTION_LIMIT = 480

  def initialize(provider: nil, now: Time.current)
    @provider = provider
    @now = now
  end

  def analyze(security)
    snapshot = security.research_snapshot
    record = SecurityHeadlineAnalysis.find_or_initialize_by(security: security)
    articles = normalized_articles(snapshot)
    digest = Digest::SHA256.hexdigest(JSON.generate(articles))

    return persist_unavailable(record, digest, snapshot, "No current imported headlines") if articles.empty? || snapshot.nil? || snapshot.stale?
    return record if record.available? && record.source_digest == digest && record.source_generated_at == snapshot.generated_at
    return persist_unavailable(record, digest, snapshot, "Jev headline analysis is not configured") unless Provider::Jev.configured?

    response = provider.decide(
      state: { ticker: security.ticker, headlines: articles },
      questions: {
        tone: { type: "choice", instructions: "Classify the aggregate tone of these dated headlines only. Do not infer a trade recommendation. Choose insufficient_evidence if the headlines do not support a directional conclusion.", criteria: TONES.index_with { |choice| nil } },
        coverage: { type: "choice", instructions: "Assess whether the supplied headline set has enough relevant, non-duplicated evidence for a cautious aggregate tone label. Choose insufficient when it does not.", criteria: COVERAGE.index_with { |choice| nil } }
      }
    )
    raise response.error unless response.success?
    decisions = response.data

    tone = decisions.value_of("tone")
    coverage = decisions.value_of("coverage")
    raise Provider::Jev::Error, "Invalid Jev headline response" unless TONES.include?(tone) && COVERAGE.include?(coverage)

    record.update!(
      source_digest: digest, source_generated_at: snapshot.generated_at, analyzed_at: @now, status: "current",
      provider_model: decisions.model.presence || Provider::Jev.effective_model,
      payload: policy_payload(articles, tone, coverage, decisions["tone"]&.confidence, decisions["coverage"]&.confidence), last_error: nil
    )
    record
  rescue Provider::Jev::Error, Faraday::Error, Timeout::Error => error
    record ||= SecurityHeadlineAnalysis.find_or_initialize_by(security: security)
    record.update!(source_digest: digest || "unavailable", source_generated_at: snapshot&.generated_at, status: "failed", payload: {}, last_error: error.message.truncate(160))
    record
  end

  private
    attr_reader :now

    def provider
      @provider ||= Provider::Jev.new(Provider::Jev.api_key)
    end

    def normalized_articles(snapshot)
      Array(snapshot&.section("news")).filter_map do |article|
        title = article["title"].to_s.squish.truncate(TITLE_LIMIT)
        next if title.blank?
        { source: article["source"].to_s.squish.truncate(80), published_at: (article["published_at"] || article["publishedAt"] || article["time"]).to_s.truncate(40), title: title, description: article["description"].to_s.squish.truncate(DESCRIPTION_LIMIT) }
      end.uniq { |article| [article[:source], article[:title]] }.first(MAX_ARTICLES)
    end

    def persist_unavailable(record, digest, snapshot, reason)
      record.update!(source_digest: digest, source_generated_at: snapshot&.generated_at, analyzed_at: nil, status: snapshot&.stale? ? "stale" : "unavailable", provider_model: nil, payload: {}, last_error: reason)
      record
    end

    def policy_payload(articles, tone, coverage, tone_confidence, coverage_confidence)
      {
        "schemaVersion" => 1,
        "policy" => { "researchOnly" => true, "brokerTruthOverride" => false, "executionWeight" => 0, "blockedUses" => %w[balances holdings valuations reports rankings orders position_sizing] },
        "analysis" => { "tone" => tone, "coverage" => coverage, "toneConfidence" => tone_confidence.to_f.clamp(0, 1), "coverageConfidence" => coverage_confidence.to_f.clamp(0, 1), "headlineCount" => articles.size }
      }
    end
end
