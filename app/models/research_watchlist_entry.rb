class ResearchWatchlistEntry < ApplicationRecord
  STATUSES = %w[watching researching ready archived].freeze

  belongs_to :user
  belongs_to :security

  validates :status, inclusion: { in: STATUSES }
  validates :priority, inclusion: { in: 1..5 }
  validates :security_id, uniqueness: { scope: :user_id }
end
