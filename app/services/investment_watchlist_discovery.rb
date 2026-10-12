# Deterministic, evidence-gated research queue generation. This is deliberately
# not a trading model: it can only queue one sourced item for a consenting user
# to research, never alter positions, prices, or an existing watchlist record.
class InvestmentWatchlistDiscovery
  Result = Data.define(:entry, :reason)
  MAX_ADDITIONS_PER_DAY = 1
  MIN_ANALYSTS = 5

  def initialize(user:, now: Time.current)
    @user, @now = user, now
  end

  def add_candidate
    return Result.new(nil, :disabled) unless user.ai_watchlist_auto_add_enabled?
    return Result.new(nil, :daily_limit) if additions_today >= MAX_ADDITIONS_PER_DAY

    ResearchWatchlistEntry.purge_expired!(user: user)
    candidate = candidates.first
    return Result.new(nil, :no_fresh_evidence) unless candidate

    entry = user.research_watchlist_entries.create!(
      security: candidate.security,
      source: "assistant",
      status: "watching",
      priority: 3,
      expires_at: user.ai_watchlist_expiry_days.days.from_now,
      thesis: candidate.thesis
    )
    Result.new(entry, :added)
  rescue ActiveRecord::RecordNotUnique
    Result.new(nil, :already_queued)
  end

  private
    Candidate = Data.define(:security, :score, :thesis)
    attr_reader :user, :now

    def additions_today
      user.research_watchlist_entries.where(source: "assistant").where(created_at: now.beginning_of_day..now.end_of_day).count
    end

    def candidates
      excluded_security_ids = user.research_watchlist_entries.active.select(:security_id)
      held_security_ids = Holding.where(account_id: user.accessible_accounts.visible.select(:id)).select(:security_id)
      Security.research_only.where.not(id: excluded_security_ids).where.not(id: held_security_ids)
        .includes(:research_snapshot, :fundamental).filter_map do |security|
          snapshot, fundamental = security.research_snapshot, security.fundamental
          next unless snapshot&.available? && !snapshot.stale? && fundamental&.available? && !fundamental.stale?
          next unless positive_consensus?(fundamental) && safe_earnings_window?(fundamental)
          Candidate.new(security, score(fundamental), thesis_for(security, snapshot, fundamental))
        end.sort_by { |candidate| [ -candidate.score, candidate.security.ticker ] }
    end

    def positive_consensus?(fundamental)
      %w[buy strong_buy].include?(fundamental.recommendation.to_s.downcase) && fundamental.analyst_count.to_i >= MIN_ANALYSTS
    end

    def safe_earnings_window?(fundamental)
      date = Date.parse(fundamental.next_earnings_date.to_s)
      !(date >= now.to_date && date <= 7.days.from_now.to_date)
    rescue Date::Error
      true
    end

    def score(fundamental)
      fundamental.analyst_count.to_i + [ fundamental.revenue_growth.to_f, 0 ].max * 10 + [ fundamental.earnings_growth.to_f, 0 ].max * 5
    end

    def thesis_for(security, snapshot, fundamental)
      growth = []
      growth << "revenue growth #{format_percent(fundamental.revenue_growth)}" if fundamental.revenue_growth.present?
      growth << "earnings growth #{format_percent(fundamental.earnings_growth)}" if fundamental.earnings_growth.present?
      facts = [ "fresh research snapshot #{snapshot.generated_at.to_date}", "#{fundamental.recommendation.to_s.humanize.downcase} consensus from #{fundamental.analyst_count.to_i} analysts", *growth ]
      "Automated research candidate for #{security.ticker}: #{facts.join('; ')}. Review the source material and risk before any decision; this is not a trade recommendation."
    end

    def format_percent(value)
      "#{(value.to_f * 100).round(1)}%"
    end
end
