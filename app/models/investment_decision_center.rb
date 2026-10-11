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

  EVENT_HORIZON_DAYS = 7
  CONCENTRATION_WEIGHT = 25
  STALE_AFTER_DAYS = 3

  attr_reader :user

  def initialize(user:, today: Date.current)
    @user = user
    @today = today
  end

  def family = user.family

  # False when the member has no investment accounts of their own to show.
  def available?
    statement.investment_accounts.any?
  end

  def pulse
    @pulse ||= begin
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

  # Things worth a decision, most urgent first. Empty means nothing is pending
  # on the evidence Sure has, which is different from "no data".
  def actions
    @actions ||= [ harvest_action, wash_sale_action, events_action, cost_basis_action ]
      .compact
      .sort_by { |action| [ -action.priority, action.kind.to_s ] }
  end

  def harvest
    @harvest ||= TaxLossHarvest.new(user: user, today: @today)
  end

  def top_holdings
    @top_holdings ||= statement.allocation.first(5)
  end

  def concentrated?(holding)
    holding.weight >= CONCENTRATION_WEIGHT
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
    def statement
      @statement ||= InvestmentStatement.new(family, user: user)
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
