# Day gain for a set of current holdings.
#
# The change from the previous trading day's close to the position's latest
# price, on the shares held at that close. Weekends and holidays carry the
# last close forward, so on a Saturday this is still Friday's move rather than
# zero. It is built from the daily price table, not from comparing yesterday's
# and today's holding snapshots: snapshots are calendar-day, repeat a stale
# feed's price for days, and differ in freshness between accounts.
#
# A position gets no figure (nil, shown as unavailable) when any of these hold,
# because a guessed number would be worse than none:
#   - its price was not refreshed this session (the snapshot is older than the
#     last trading day), so "today's move" is not known;
#   - the security has no close for the previous trading day, or in another
#     currency than the holding;
#   - the share count differs from the count held at that close, or the
#     position did not exist then, so a trade would be mistaken for a market gain.
class Holding::DayChange
  LOOKBACK_DAYS = 7

  def self.for(holdings, today: Date.current)
    new(holdings, today: today).trends
  end

  def initialize(holdings, today: Date.current)
    @holdings = Array(holdings).compact
    @today = today
  end

  # { holding.id => Trend or nil }
  def trends
    @trends ||= @holdings.index_by(&:id).transform_values { |holding| trend_for(holding) }
  end

  # The most recent weekday on or before today. Holiday closures simply carry
  # the previous close, which reads as no change for that day.
  def session_date
    @session_date ||= last_weekday(@today)
  end

  # The weekday before the session: the close the move is measured from.
  def reference_date
    @reference_date ||= last_weekday(session_date - 1.day)
  end

  private
    def trend_for(holding)
      return nil if holding.qty.to_d.zero? || holding.price.nil?
      return nil if holding.date < session_date

      close = closes[holding.security_id]
      return nil if close.nil? || close.currency != holding.currency

      reference = reference_holdings[[ holding.account_id, holding.security_id, holding.currency ]]
      return nil if reference.nil? || reference.qty.to_d != holding.qty.to_d

      qty = holding.qty.to_d
      Trend.new(
        current: Money.new(qty * holding.price.to_d, holding.currency),
        previous: Money.new(qty * close.price.to_d, holding.currency)
      )
    end

    # Close on the reference date, or the latest earlier weekday that has one
    # (a holiday or a feed gap), looking back at most a week.
    def closes
      @closes ||= begin
        ids = @holdings.map(&:security_id).uniq
        rows = Security::Price.where(security_id: ids, date: (reference_date - LOOKBACK_DAYS)..reference_date)
                              .where("EXTRACT(DOW FROM date) BETWEEN 1 AND 5")
                              .order(:security_id, date: :desc).to_a
        rows.group_by(&:security_id).transform_values(&:first)
      end
    end

    # The position as held at the reference close: the latest snapshot on or
    # before the reference date, per account, security and currency.
    def reference_holdings
      @reference_holdings ||= begin
        return {} if @holdings.empty?

        Holding.where(id: Holding.where(account_id: @holdings.map(&:account_id).uniq, security_id: @holdings.map(&:security_id).uniq)
                                 .where(date: (reference_date - LOOKBACK_DAYS)..reference_date)
                                 .select("DISTINCT ON (account_id, security_id, currency) id")
                                 .order("account_id, security_id, currency, date DESC"))
               .select(:id, :account_id, :security_id, :currency, :qty, :date)
               .index_by { |holding| [ holding.account_id, holding.security_id, holding.currency ] }
      end
    end

    def last_weekday(date)
      date -= 1.day while date.saturday? || date.sunday?
      date
    end
end
