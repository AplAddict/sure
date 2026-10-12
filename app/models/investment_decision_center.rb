# Decision-first view of ONE member's investments: where the portfolio stands,
# what needs a decision, and what to keep an eye on. A read-only projection.
#
# Scope is the viewer's own accessible accounts (InvestmentStatement and
# TaxLossHarvest both take the user), so it can never show another family
# member's holdings. Anything it cannot measure is nil or listed as
# unavailable; it is never rendered as zero. It makes no recommendation to
# trade: "actions" are review prompts that link to the page with the evidence.
class InvestmentDecisionCenter
  # kind: :harvest | :wash_sale | :events | :cost_basis
  Action = Data.define(:kind, :count, :detail, :priority)

  Pulse = Data.define(
    :portfolio_value, :holdings_value, :cash_balance, :day_change,
    :unrealized, :as_of, :stale
  )
  SourceHealth = Data.define(:key, :label, :status, :detail)

  EVENT_HORIZON_DAYS = 7
  CONCENTRATION_WEIGHT = 25
  STALE_AFTER_DAYS = 3
  ACTIONS_CACHE_TTL = 15.minutes

  attr_reader :user

  def initialize(user:, today: Date.current)
    @user = user
    @today = today
    @failed_sections = []
  end

  # Sections that raised while loading. The page shows these as unavailable
  # instead of failing as a whole, and never as "nothing to do".
  attr_reader :failed_sections

  def failed?(section) = failed_sections.include?(section)

  def family = user.family

  # False when the member has no investment accounts of their own to show.
  def available?
    # If even this cannot be answered the view switch is hidden and the normal
    # overview shows, rather than the whole homepage failing.
    guarded(:available) { statement.investment_accounts.any? } || false
  end

  # nil when it could not be computed (see failed?(:pulse)).
  def pulse
    return @pulse if defined?(@pulse)

    @pulse = guarded(:pulse) do
      # The OLDEST per-account snapshot decides freshness: one up-to-date
      # account must not make a stale one look current.
      as_of = statement.current_holdings.to_a.group_by(&:account_id).values.map { |rows| rows.map(&:date).max }.min
      Pulse.new(
        portfolio_value: statement.portfolio_value_money,
        holdings_value: statement.holdings_value_money,
        cash_balance: statement.cash_balance_money,
        day_change: statement.day_change,
        unrealized: statement.unrealized_gains_trend,
        as_of: as_of,
        stale: as_of.nil? || (@today - as_of).to_i > STALE_AFTER_DAYS
      )
    end
  end

  # Things worth a decision, most urgent first. An empty list means nothing is
  # pending on the evidence Sure has; nil means the list could not be built,
  # which is different from "nothing pending" and is never shown as it.
  #
  # Building it walks every position and trade, so the result is cached per
  # member until the family's data next syncs (or a quarter hour passes).
  def actions
    return @actions if defined?(@actions)

    @actions = guarded(:actions) do
      rows = Rails.cache.fetch(actions_cache_key, expires_in: ACTIONS_CACHE_TTL) { build_actions.map { |action| dump_action(action) } }
      rows.map { |row| load_action(row) }
    end
  end

  def harvest
    @harvest ||= TaxLossHarvest.new(user: user, today: @today)
  end

  def top_holdings
    return @top_holdings if defined?(@top_holdings)

    @top_holdings = guarded(:top_holdings) { statement.allocation.first(5) }
  end

  def concentrated?(holding)
    holding.weight >= CONCENTRATION_WEIGHT
  end

  # Trust rail: availability and freshness of the evidence already used by this
  # member's center. It does not add a competing action queue or imply advice.
  def source_health
    return @source_health if defined?(@source_health)

    @source_health = guarded(:source_health) do
      snapshot = pulse
      holdings = if snapshot.nil? || snapshot.as_of.nil?
        SourceHealth.new(key: :holdings, label: "Holdings snapshot", status: "unavailable", detail: "No dated holdings snapshot is available")
      elsif snapshot.stale
        SourceHealth.new(key: :holdings, label: "Holdings snapshot", status: "stale", detail: "As of #{snapshot.as_of}")
      else
        SourceHealth.new(key: :holdings, label: "Holdings snapshot", status: "current", detail: "As of #{snapshot.as_of}")
      end

      gaps = harvest.unavailable.select { |item| item.reason == :cost_basis_unknown }
      basis = if gaps.any?
        SourceHealth.new(key: :basis, label: "Cost basis coverage", status: "unavailable", detail: "#{gaps.size} position#{'s' if gaps.size != 1} without known basis")
      else
        SourceHealth.new(key: :basis, label: "Cost basis coverage", status: "current", detail: "Known for the positions used in this view")
      end
      events = market_events_source_health
      [ holdings, basis, events ]
    end
  end

  def upcoming_events
    @upcoming_events ||= calendar_events.select do |event|
      event.event_type.in?(%w[earnings ex_dividend]) &&
        event.freshness == "current" &&
        event.date.between?(@today, @today + EVENT_HORIZON_DAYS.days)
    end
  end

  def open_wash_sale_windows
    @open_wash_sale_windows ||= calendar_events.select do |event|
      event.event_type == "wash_sale" && event.date <= @today && event.end_date >= @today
    end
  end

  private
    def guarded(section)
      yield
    rescue StandardError => e
      @failed_sections << section
      Rails.logger.error("[InvestmentDecisionCenter] #{section} failed for user #{user.id}: #{e.class}: #{e.message.truncate(200)}")
      Sentry.capture_exception(e) { |scope| scope.set_tags(decision_center_section: section) } if defined?(Sentry)
      nil
    end

    def build_actions
      [ harvest_action, wash_sale_action, events_action, cost_basis_action ]
        .compact
        .sort_by { |action| [ -action.priority, action.kind.to_s ] }
    end

    # Keyed to the member (their accounts decide what they see) and the day, and
    # to the family's last completed sync so fresh data is never hidden behind it.
    def actions_cache_key
      [ family.build_cache_key("decision_center_actions_v1", invalidate_on_data_updates: true), user.id, @today.iso8601 ]
    end

    # Cached as plain values: a Money inside a Data object is not worth betting a
    # page load on surviving serialization.
    def dump_action(action)
      detail = action.detail.is_a?(Money) ? { "money" => [ action.detail.amount.to_s, action.detail.currency.iso_code ] } : action.detail
      { "kind" => action.kind.to_s, "count" => action.count, "detail" => detail, "priority" => action.priority }
    end

    def load_action(row)
      detail = row["detail"]
      detail = Money.new(BigDecimal(detail["money"].first), detail["money"].last) if detail.is_a?(Hash) && detail["money"]
      Action.new(kind: row["kind"].to_sym, count: row["count"], detail: detail, priority: row["priority"])
    end

    def statement
      @statement ||= InvestmentStatement.new(family, user: user)
    end

    def market_events_source_health
      events = guarded(:events) { calendar_events }
      return SourceHealth.new(key: :events, label: "Market events & wash-sale evidence", status: "unavailable", detail: "Calendar evidence could not be loaded") if events.nil?

      stale = events.count { |event| event.freshness == "stale" }
      if stale.positive?
        SourceHealth.new(key: :events, label: "Market events & wash-sale evidence", status: "stale", detail: "#{stale} event#{'s' if stale != 1} use stale source data")
      else
        SourceHealth.new(key: :events, label: "Market events & wash-sale evidence", status: "current", detail: "#{events.size} sourced or calculated event#{'s' if events.size != 1} checked")
      end
    end

    def calendar_events
      @calendar_events ||= MarketCalendar::EventBuilder.new(accounts: user.accessible_accounts.visible).events
    end

    def harvest_action
      candidates = harvest.candidates
      return nil if candidates.empty?

      loss = candidates.sum(BigDecimal("0")) { |row| row.loss.amount.abs }
      Action.new(kind: :harvest, count: candidates.size, detail: Money.new(loss, family.currency), priority: @today.month >= 11 ? 3 : 2)
    end

    def wash_sale_action
      windows = open_wash_sale_windows
      return nil if windows.empty?

      replaced = windows.count { |event| event.details.include?("replacement shares are recorded") }
      Action.new(kind: :wash_sale, count: windows.size, detail: replaced, priority: replaced.positive? ? 3 : 1)
    end

    def events_action
      events = upcoming_events
      return nil if events.empty?

      Action.new(kind: :events, count: events.size, detail: events.map(&:ticker).uniq.sort.first(4), priority: events.any? { |e| e.event_type == "earnings" } ? 2 : 1)
    end

    def cost_basis_action
      gaps = harvest.unavailable.select { |item| item.reason == :cost_basis_unknown }
      return nil if gaps.empty?

      Action.new(kind: :cost_basis, count: gaps.size, detail: gaps.map(&:ticker).uniq.sort.first(3), priority: 0)
    end
end
