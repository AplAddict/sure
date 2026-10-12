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

  # Only assistant-added entries ever carry an expiry. Hidden the moment they
  # lapse (the daily sweep only reclaims the rows), so the list is never stale.
  scope :expired, -> { where(source: "assistant").where("expires_at <= ?", Time.current) }
  scope :active, -> { where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def assistant_added?
    source == "assistant"
  end

  def expires?
    expires_at.present?
  end

  # The member reviewed it and wants it: stop the clock. The "added by assistant"
  # label stays so where it came from is still visible.
  def keep!
    update!(expires_at: nil)
  end

  def self.assistant_adds_today_for(user)
    where(user: user, source: "assistant").where(created_at: 24.hours.ago..).count
  end

  # Deletes lapsed assistant entries (all, or one member's). Returns the count.
  def self.purge_expired!(user: nil)
    scope = expired
    scope = scope.where(user: user) if user
    scope.delete_all
  end
end
