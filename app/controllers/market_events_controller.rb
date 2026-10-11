class MarketEventsController < ApplicationController
  EVENT_TYPES = %w[earnings ex_dividend options_expiration wash_sale].freeze

  def index
    @from = parse_date(params[:from]) || Date.current
    @to = parse_date(params[:to]) || (@from + 60.days)
    @to = @from + 180.days if @to > @from + 180.days
    @event_type = EVENT_TYPES.include?(params[:type]) ? params[:type] : ""

    builder = MarketCalendar::EventBuilder.new(accounts: Current.user.accessible_accounts, now: Time.current)
    all_events = builder.events
    @wash_sale_status = builder.wash_sale_status
    @wash_sale_events = all_events.select { |event| event.event_type == "wash_sale" }
    @wash_sale_insights = {
      open: @wash_sale_events.count { |event| event.date <= Date.current && event.end_date >= Date.current },
      upcoming: @wash_sale_events.count { |event| event.date > Date.current },
      replacement_evidence: @wash_sale_events.count { |event| event.details.include?("replacement shares are recorded") },
      next_deadline: @wash_sale_events.select { |event| event.end_date >= Date.current }.map(&:end_date).min
    }
    @events = all_events.select { |event| event.date <= @to && event.end_date >= @from }
    @events = @events.select { |event| event.event_type == @event_type } if @event_type.present?
  end

  private
    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
end
