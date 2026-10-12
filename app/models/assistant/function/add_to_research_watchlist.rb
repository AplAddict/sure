# Lets the member's AI assistant queue a ticker on the member's own research
# watchlist. It is opt-in per member (User#ai_watchlist_enabled?), additive only
# (it never edits or removes anything, and never overwrites an entry the member
# already has), rate-limited, expires on its own, and research-only: it cannot trade, change holdings
# or touch anyone else's list.
class Assistant::Function::AddToResearchWatchlist < Assistant::Function
  class << self
    def name
      "add_to_research_watchlist"
    end

    def description
      <<~INSTRUCTIONS
        Adds a stock or ETF ticker to the user's private research watchlist so they can review it later.

        Use this only when the user asks you to track, watch or queue a ticker, or agrees to a suggestion you made.
        It is research context only: it does not buy, sell, or change any holdings. It never changes a ticker
        the user already has on the list. Entries you add lapse automatically (the user chooses how long in
        Preferences) unless they keep them, so add only what is worth a fresh look. Tell the user which
        ticker you added and why.

        Example:

        ```
        add_to_research_watchlist({ ticker: "NVDA", thesis: "Check data-center margin trend", priority: 2 })
        ```
      INSTRUCTIONS
    end
  end

  # Tool definitions are built for a particular user, so state the actual
  # permission in the instructions rather than trusting the model to infer it.
  def description
    base = self.class.description
    if user_allows_automatic_adds?
      base + <<~INSTRUCTIONS

        The user enabled automatic additions. You may automatically add a ticker when you identify a
        substantive research candidate that directly fits the user's stated investment interests or a
        concrete thesis already under discussion. Do not add a ticker merely because it was mentioned,
        is a passing comparison, or is broad market/news context. Say clearly that you added it, why,
        and when it will expire unless kept.
      INSTRUCTIONS
    else
      base + <<~INSTRUCTIONS

        The user did not enable automatic additions. Add a ticker only when the user explicitly asks
        you to watch, track, or queue it, or explicitly agrees to your recommendation.
      INSTRUCTIONS
    end
  end

  def user_allows_automatic_adds?
    user.ai_watchlist_auto_add_enabled?
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "ticker" ],
      properties: {
        ticker: { type: "string", description: "Ticker symbol, for example AAPL or BRK-B" },
        thesis: { type: "string", description: "Short note on why it is worth researching, or what to validate (max 2000 characters)" },
        priority: { type: "integer", description: "1 (highest) to 5 (lowest). Defaults to 3." }
      }
    )
  end

  def call(params = {})
    return failure("setting_disabled", "The user has not allowed the assistant to add to their research watchlist. They can turn this on in Preferences.") unless user.ai_watchlist_enabled?

    if ResearchWatchlistEntry.assistant_adds_today_for(user) >= ResearchWatchlistEntry::ASSISTANT_ADDS_PER_DAY
      return failure("daily_limit", "The assistant has already added #{ResearchWatchlistEntry::ASSISTANT_ADDS_PER_DAY} tickers in the last 24 hours. Ask the user to add more themselves.")
    end

    # A lapsed leftover must not block a fresh add of the same ticker.
    ResearchWatchlistEntry.purge_expired!(user: user)

    ticker = params["ticker"].to_s.strip.upcase
    security, status = TickerResearchGenerateJob.resolve_security(ticker)
    case status
    when :invalid then return failure("invalid_ticker", "\"#{ticker}\" does not look like a ticker symbol.")
    when :unknown then return failure("unknown_ticker", "#{ticker} is not a known ticker.")
    when :unavailable then return failure("lookup_unavailable", "#{ticker} could not be checked right now, so nothing was added.")
    end

    if user.research_watchlist_entries.exists?(security_id: security.id)
      return failure("already_on_watchlist", "#{ticker} is already on the user's watchlist; it was left unchanged.")
    end

    entry = user.research_watchlist_entries.new(
      security: security,
      source: "assistant",
      expires_at: user.ai_watchlist_expiry_days.days.from_now,
      status: "watching",
      priority: priority_from(params["priority"]),
      thesis: params["thesis"].to_s.strip.first(2000).presence
    )

    if entry.save
      TickerResearchGenerateJob.perform_later(ticker, enrich_only: true) if status == :created
      { success: true, ticker: ticker, expires_at: entry.expires_at.to_date.iso8601, message: "#{ticker} added to the user's research watchlist. It expires on #{entry.expires_at.to_date.iso8601} unless the user keeps it." }
    else
      failure("validation_failed", entry.errors.full_messages.join("; "))
    end
  end

  private
    def priority_from(value)
      value.to_i.between?(1, 5) ? value.to_i : 3
    end

    def failure(key, message)
      { success: false, error: key, message: message }
    end
end
