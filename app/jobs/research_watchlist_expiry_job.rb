# Reclaims assistant-added watchlist entries whose expiry has passed. They are
# already hidden from the list the moment they lapse; this just frees the rows.
# A member's own entries never expire, and one they kept has no expiry.
class ResearchWatchlistExpiryJob < ApplicationJob
  queue_as :scheduled

  def perform
    removed = ResearchWatchlistEntry.purge_expired!
    Rails.logger.info("ResearchWatchlistExpiryJob removed #{removed} expired assistant entries") if removed.positive?
  end
end
