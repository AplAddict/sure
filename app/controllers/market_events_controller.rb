class MarketEventsController < ApplicationController
  EVENT_TYPES = %w[earnings ex_dividend options_expiration wash_sale].freeze

  def index
    @from = parse_date(params[:from]) || Date.current
    @to = parse_date(params[:to]) || (@from + 60.days)
    @to = @from + 180.days if @to > @from + 180.days
    @event_type = EVENT_TYPES.include?(params[:type]) ? params[:type] : ""

    builder = MarketCalendar::EventBuilder.new(accounts: Current.user.accessible_accounts, now: Time.current)
    @wash_sale_status = builder.wash_sale_status
    @events = builder.events.select { |event| event.date.between?(@from, @to) }
    @events = @events.select { |event| event.event_type == @event_type } if @event_type.present?
  end

  private
    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end
end
