# Typed, cache-only analysis of imported ticker headlines. It is research context
# only and must never feed holdings, prices, valuation, reports, rankings, or orders.
class SecurityHeadlineAnalysis < ApplicationRecord
  belongs_to :security

  STATUSES = %w[current stale unavailable failed].freeze
  validates :status, inclusion: { in: STATUSES }

  def available?
    status == "current" && payload.present? && analyzed_at.present?
  end

  def stale?
    status == "stale" || analyzed_at.blank? || analyzed_at < 36.hours.ago
  end
end
