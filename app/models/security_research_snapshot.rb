# Cached, read-only reference material for a held security.  It is never used
# for balances, holdings, reporting, valuations, order execution or rankings.
class SecurityResearchSnapshot < ApplicationRecord
  belongs_to :security

  STALE_AFTER = 36.hours
  STATUSES = %w[current stale unavailable invalid].freeze

  validates :status, inclusion: { in: STATUSES }

  def available?
    payload.present? && imported_at.present? && !invalid?
  end

  def stale?
    !available? || generated_at.blank? || generated_at < STALE_AFTER.ago
  end

  def invalid?
    status == "invalid"
  end

  def section(name)
    payload[name.to_s] || {}
  end
end
