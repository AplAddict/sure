class ResearchWatchlistEntry < ApplicationRecord
  STATUSES = %w[watching researching ready archived].freeze
  SOURCES = %w[user assistant].freeze
  # How many entries the member's AI assistant may add in a rolling day. It is a
  # research queue the member reviews, so a runaway chat cannot flood it.
  ASSISTANT_ADDS_PER_DAY = 10

  belongs_to :user
  belongs_to :security

  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }
  validates :priority, inclusion: { in: 1..5 }
  validates :security_id, uniqueness: { scope: :user_id }

  def assistant_added?
    source == "assistant"
  end

  def self.assistant_adds_today_for(user)
    where(user: user, source: "assistant").where(created_at: 24.hours.ago..).count
  end
end
