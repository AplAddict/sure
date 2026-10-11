# Read-only iCal feed for the signed-in member's Events calendar. It publishes
# recurring bills/paydays plus the native, holdings-derived market projection.
# It never imports an external calendar, exposes balances/accounts, writes to
# brokerage providers, or shares another member's accessible-account data.
class BillsFeedsController < ApplicationController
  skip_authentication

  HORIZON_DAYS = 90

  def show
    payload = Family.bills_feed_verifier.verified(params[:token].to_s)
    user_id, stamp = payload if payload.is_a?(Array)
    user = User.find_by(id: user_id)
    family = user&.family
    raise ActiveRecord::RecordNotFound unless family && stamp.present? && stamp == family.bills_feed_stamp

    # The token carries a member identity, rather than the family identity. A
    # retained URL must also die when the member opts out or recurring is off.
    raise ActiveRecord::RecordNotFound unless user.preview_features_enabled? && !family.recurring_transactions_disabled?

    I18n.with_locale(family.locale.presence || I18n.default_locale) do
      render plain: to_ical(user:, family:), content_type: "text/calendar"
    end
  rescue ActiveRecord::RecordNotFound
    head :not_found
  end

  private
    def to_ical(user:, family:)
      events = bill_events(user, family) + paycheck_events(user, family) + market_events(user)

      <<~ICAL
        BEGIN:VCALENDAR
        VERSION:2.0
        PRODID:-//Sure//Events//EN
        X-WR-CALNAME:Events
        X-WR-CALDESC:Sure bills\, paydays\, and private holdings-derived market events
        #{events.sort_by { |event| [ event[:date], event[:summary] ] }.map { |event| event_to_ical(event) }.join}
        END:VCALENDAR
      ICAL
    end

    def bill_events(user, family)
      recurring_occurrences(user, family)
        .where("recurring_transactions.amount > 0")
        .map do |occurrence|
          series = occurrence.recurring_transaction
          amount = Money.new(occurrence.resolved_expected_amount, occurrence.currency).format
          calendar_event(
            uid: "bill-#{occurrence.id}@sure-events",
            date: occurrence.effective_due_on,
            summary: "#{series.display_name} (#{amount})",
            categories: "Bills",
            description: "Scheduled bill in Sure."
          )
        end
    end

    def paycheck_events(user, family)
      recurring_occurrences(user, family)
        .where(recurring_transactions: { bill_type: :income, manual: true })
        .map do |occurrence|
          series = occurrence.recurring_transaction
          amount = Money.new(occurrence.resolved_expected_amount, occurrence.currency).format
          calendar_event(
            uid: "paycheck-#{occurrence.id}@sure-events",
            date: occurrence.due_on,
            summary: "Payday — #{series.display_name} (#{amount})",
            categories: "Income",
            description: "Expected paycheck in Sure."
          )
        end
    end

    def recurring_occurrences(user, family)
      family.recurring_occurrences
            .open_status
            .joins(:recurring_transaction)
            .merge(RecurringTransaction.accessible_by(user))
            .where(recurring_transactions: { status: :active })
            .where(due_on: Date.current..(Date.current + HORIZON_DAYS))
            .includes(:recurring_transaction)
            .order(:due_on)
    end

    def market_events(user)
      MarketCalendar::EventBuilder.new(accounts: user.accessible_accounts).events.filter_map do |event|
        # A wash-sale window opened before today is still useful if its end is
        # upcoming. All other native events are upcoming only.
        next if event.end_date < Date.current || event.date > Date.current + HORIZON_DAYS

        calendar_event(
          uid: "market-#{Digest::SHA256.hexdigest(event.key)}@sure-events",
          date: event.date,
          end_date: event.end_date,
          summary: market_summary(event),
          categories: market_categories(event),
          description: market_description(event)
        )
      end
    end

    def market_summary(event)
      return event.title unless event.event_type == "wash_sale"

      "#{event.ticker} — Wash-sale window: #{event.date.strftime("%b %-d")} to #{event.end_date.strftime("%b %-d, %Y")}"
    end

    def market_description(event)
      if event.event_type == "wash_sale"
        "Wash-sale watch window starts #{event.date.strftime("%B %-d, %Y")} and ends #{event.end_date.strftime("%B %-d, %Y")} (inclusive). #{event.details} Source: #{event.source}. Freshness: #{event.freshness}."
      else
        "#{event.details} Source: #{event.source}. Freshness: #{event.freshness}."
      end
    end

    def market_categories(event)
      {
        "earnings" => "Earnings",
        "ex_dividend" => "Dividends",
        "options_expiration" => "Trading",
        "wash_sale" => "Trading,Wash Sales"
      }.fetch(event.event_type, "Market")
    end

    def calendar_event(uid:, date:, summary:, categories:, description:, end_date: date)
      { uid:, date:, end_date:, summary:, categories:, description: }
    end

    def event_to_ical(event)
      # DTEND is exclusive for all-day VEVENTs. A one-day event therefore ends
      # tomorrow; a wash window visually includes its statutory final date.
      <<~EVENT
        BEGIN:VEVENT
        UID:#{event[:uid]}
        DTSTAMP:#{Time.current.utc.strftime("%Y%m%dT%H%M%SZ")}
        DTSTART;VALUE=DATE:#{event[:date].strftime("%Y%m%d")}
        DTEND;VALUE=DATE:#{(event[:end_date] + 1.day).strftime("%Y%m%d")}
        SUMMARY:#{escape_ical(event[:summary])}
        CATEGORIES:#{escape_ical(event[:categories])}
        DESCRIPTION:#{escape_ical(event[:description])}
        BEGIN:VALARM
        TRIGGER:-PT1440M
        ACTION:DISPLAY
        DESCRIPTION:#{escape_ical(event[:summary])}
        END:VALARM
        END:VEVENT
      EVENT
    end

    def escape_ical(text)
      text.to_s.gsub("\\", "\\\\").gsub(",", "\\,").gsub(";", "\\;").gsub("\n", "\\n")
    end
end
