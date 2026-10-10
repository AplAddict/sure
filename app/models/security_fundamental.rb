# Cached stock data for one security (valuation, margins, analyst view, next
# earnings). It is display context only: nothing here feeds balances, holdings
# or reports. A figure the source did not supply is nil and rendered as
# "unavailable" — never as zero.
class SecurityFundamental < ApplicationRecord
  belongs_to :security

  STALE_AFTER = 36.hours

  FIELDS = %w[
    currency market_cap trailing_pe forward_pe beta dividend_yield dividend_rate payout_ratio
    ex_dividend_date fifty_two_week_high fifty_two_week_low profit_margin operating_margin
    revenue_growth earnings_growth return_on_equity recommendation target_mean_price analyst_count
    strong_buy buy hold sell strong_sell next_earnings_date
  ].freeze

  FIELDS.each do |field|
    define_method(field) { payload[field] }
  end

  def available?
    fetched_at.present? && payload.present?
  end

  def stale?
    fetched_at.nil? || fetched_at < STALE_AFTER.ago
  end

  def ratings
    counts = %w[strong_buy buy hold sell strong_sell].index_with { |key| payload[key] }
    counts.values.all?(&:nil?) ? nil : counts
  end

  def rating_total
    ratings&.values&.compact&.sum
  end

  # Rows the refresher should (re)try, oldest data first. A failed attempt backs
  # off for an hour so a throttled source is not hammered.
  def self.refresh_candidates(securities)
    existing = where(security_id: securities.map(&:id)).index_by(&:security_id)

    securities
      .select do |security|
        record = existing[security.id]
        record.nil? || ((record.stale?) && (record.last_attempt_at.nil? || record.last_attempt_at < 1.hour.ago))
      end
      .sort_by { |security| existing[security.id]&.fetched_at || Time.at(0) }
  end
end
