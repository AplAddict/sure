# Earnings and ex-dividend dates landing in the next week on securities a
# member holds. Only fresh cached market data is used; stale dates are
# skipped rather than shown as upcoming events.
class Insight::Generators::PositionEventsGenerator < Insight::Generator
  produces "position_events"

  HORIZON_DAYS = 7
  MAX_LISTED = 4

  def generate
    events = upcoming_events
    return [] if events.empty?

    earnings = events.select { |event| event.event_type == "earnings" }
    listed = events.first(MAX_LISTED).map { |event| "#{event.ticker} (#{label(event)} #{I18n.l(event.date, format: :short)})" }
    window_end = Date.current + HORIZON_DAYS.days

    [
      build_insight(
        insight_type: "position_events",
        priority: earnings.any? ? "medium" : "low",
        title: I18n.t("insights.titles.position_events", count: events.size),
        template_key: "position_events",
        facts: {
          count: events.size,
          events: listed.to_sentence,
          more: [ events.size - MAX_LISTED, 0 ].max
        },
        metadata: { events: events.map { |event| "#{event.ticker}:#{event.event_type}:#{event.date.iso8601}" }.sort },
        period: Struct.new(:start_date, :end_date).new(Date.current, window_end),
        dedup_key: user_key("position_events", Date.current.strftime("%G-W%V"))
      )
    ]
  end

  private
    def upcoming_events
      today = Date.current
      MarketCalendar::EventBuilder.new(accounts: user.accessible_accounts.visible)
        .events
        .select do |event|
          event.event_type.in?(%w[earnings ex_dividend]) &&
            event.freshness == "current" &&
            event.date.between?(today, today + HORIZON_DAYS.days)
        end
    end

    def label(event)
      I18n.t("insights.position_event_labels.#{event.event_type}")
    end
end
