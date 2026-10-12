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
#   - its price was not refreshed this session: the snapshot is older than the
#     session day, or was last written before that session's market open (a
#     price written overnight is the previous close carried forward, so a
#     "move" computed from it is a flat zero that never happened);
#   - the security has no close for the previous trading day, or in another
#     currency than the holding;
#   - the share count differs from the count held at that close, or the
#     position did not exist then, so a trade would be mistaken for a market gain.
class Holding::DayChange
  LOOKBACK_DAYS = 7

  MARKET_ZONE = "America/New_York".freeze
  MARKET_OPEN = [ 9, 30 ].freeze

  def self.for(holdings, today: Date.current, now: Time.current)
    new(holdings, today: today, now: now).trends
  end

  def initialize(holdings, today: Date.current, now: Time.current)
    @holdings = Array(holdings).compact
    @today = today
    @now = now
  end

  # { holding.id => Trend or nil }
  def trends
    @trends ||= @holdings.index_by(&:id).transform_values { |holding| trend_for(holding) }
  end

  # The most recent weekday on or before today. Holiday closures simply carry
  # the previous close, which reads as no change for that day.
  def session_date
    @session_date ||= begin
      zone = ActiveSupport::TimeZone[MARKET_ZONE]
      local = @now.in_time_zone(zone)
      opened = local.to_date.on_weekday? && local >= market_open(local.to_date)
      opened ? local.to_date : last_weekday(local.to_date - 1.day)
    end
  end

  # When the session opened, in absolute time.
  def session_open
    @session_open ||= market_open(session_date)
  end

  # The weekday before the session: the close the move is measured from.
  def reference_date
    @reference_date ||= last_weekday(session_date - 1.day)
  end

  private
    def trend_for(holding)
      return nil if holding.qty.to_d.zero? || holding.price.nil?
      return nil if holding.date < session_date

      price = current_price(holding)
      return nil if price.nil?

      close = closes[holding.security_id]
      return nil if close.nil? || close.currency != holding.currency

      reference = reference_holdings[[ holding.account_id, holding.security_id, holding.currency ]]
      return nil if reference.nil? || reference.qty.to_d != holding.qty.to_d

      qty = holding.qty.to_d
      Trend.new(
        current: Money.new(qty * price, holding.currency),
        previous: Money.new(qty * close.price.to_d, holding.currency)
      )
    end

    # The latest price known to be from this session: a live quote written after
    # the open (Security::IntradayPriceRefresher), else the broker snapshot's own
    # price if that was itself written after the open. Anything older is the
    # previous close carried forward and is not a price for today.
    def current_price(holding)
      live = live_prices[holding.security_id]
      return live.price.to_d if live && live.currency == holding.currency

      holding.updated_at && holding.updated_at >= session_open ? holding.price.to_d : nil
    end

    def live_prices
      @live_prices ||= Security::Price.where(security_id: @holdings.map(&:security_id).uniq, date: session_date)
                                      .where("updated_at >= ?", session_open).where("price > 0")
                                      .index_by(&:security_id)
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

    def market_open(date)
      ActiveSupport::TimeZone[MARKET_ZONE].local(date.year, date.month, date.day, *MARKET_OPEN)
    end

    def last_weekday(date)
      date -= 1.day while date.saturday? || date.sunday?
      date
    end
end
