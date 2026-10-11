# Open 30-day windows after a recorded loss sale, in the accounts one member
# can see. Calculated from recorded trades (MarketCalendar::EventBuilder), so
# it is a review prompt: the broker's own adjustment is the authority.
class Insight::Generators::WashSaleWindowGenerator < Insight::Generator
  produces "wash_sale_window"

  MAX_LISTED = 3

  def generate
    windows = open_windows
    return [] if windows.empty?

    replaced = windows.select { |event| event.details.include?("replacement shares are recorded") }
    tickers = windows.map(&:ticker).uniq.sort
    ends_on = windows.map(&:end_date).min

    [
      build_insight(
        insight_type: "wash_sale_window",
        priority: replaced.any? ? "high" : "low",
        title: I18n.t("insights.titles.wash_sale_window", count: windows.size),
        template_key: replaced.any? ? "wash_sale_window.replaced" : "wash_sale_window.open",
        facts: {
          count: windows.size,
          tickers: tickers.first(MAX_LISTED).to_sentence,
          replaced: replaced.map(&:ticker).uniq.size,
          next_end: I18n.l(ends_on, format: :long)
        },
        metadata: {
          tickers: tickers,
          replaced_tickers: replaced.map(&:ticker).uniq.sort,
          next_end: ends_on.iso8601
        },
        period: Struct.new(:start_date, :end_date).new(Date.current, windows.map(&:end_date).max),
        dedup_key: user_key("wash_sale_window", month_token)
      )
    ]
  end

  private
    def open_windows
      today = Date.current
      MarketCalendar::EventBuilder.new(accounts: user.accessible_accounts.visible)
        .events
        .select { |event| event.event_type == "wash_sale" && event.date <= today && event.end_date >= today }
    end
end
