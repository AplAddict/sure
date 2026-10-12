require "test_helper"

class ResearchWatchlistEntryTest < ActiveSupport::TestCase
  setup do
    @security = Security.create!(ticker: "WATCH#{SecureRandom.hex(3)}", exchange_mic: "XNAS", name: "Watchlist Test")
  end

  test "a watchlist entry belongs to one user and security with a bounded research-only status" do
    entry = ResearchWatchlistEntry.new(user: users(:family_admin), security: @security, status: "watching", priority: 3, thesis: "Validate the next earnings release")

    assert_predicate entry, :valid?
    assert_equal "watching", entry.status
    assert_equal 3, entry.priority
  end

  test "a user cannot create duplicate entries for the same security" do
    user = users(:family_admin)
    security = @security
    ResearchWatchlistEntry.create!(user: user, security: security, status: "watching", priority: 3)

    duplicate = ResearchWatchlistEntry.new(user: user, security: security, status: "researching", priority: 2)
    assert_not_predicate duplicate, :valid?
  end

  test "purge_expired! removes only expired assistant entries, never the member's own" do
    user = users(:family_admin)
    sec = ->(name) { Security.create!(ticker: Array.new(5) { ("A".."Z").to_a.sample }.join, exchange_mic: "XNAS", name: name) }
    expired_ai = ResearchWatchlistEntry.create!(user: user, security: sec.("A"), source: "assistant", expires_at: 1.day.ago)
    live_ai = ResearchWatchlistEntry.create!(user: user, security: sec.("B"), source: "assistant", expires_at: 5.days.from_now)
    kept_ai = ResearchWatchlistEntry.create!(user: user, security: sec.("C"), source: "assistant", expires_at: nil)
    mine = ResearchWatchlistEntry.create!(user: user, security: sec.("D"), source: "user", expires_at: 1.day.ago)

    assert_equal 1, ResearchWatchlistEntry.purge_expired!

    assert_not ResearchWatchlistEntry.exists?(expired_ai.id)
    assert ResearchWatchlistEntry.exists?(live_ai.id)
    assert ResearchWatchlistEntry.exists?(kept_ai.id)
    assert ResearchWatchlistEntry.exists?(mine.id), "a member's own entry never expires"
  end

  test "active hides expired entries immediately, before the sweep runs" do
    user = users(:family_admin)
    sec = Security.create!(ticker: Array.new(5) { ("A".."Z").to_a.sample }.join, exchange_mic: "XNAS", name: "Hidden")
    ResearchWatchlistEntry.create!(user: user, security: sec, source: "assistant", expires_at: 1.minute.ago)

    assert_empty user.research_watchlist_entries.active
  end

  test "keep! makes an assistant entry permanent" do
    user = users(:family_admin)
    sec = Security.create!(ticker: Array.new(5) { ("A".."Z").to_a.sample }.join, exchange_mic: "XNAS", name: "Keep")
    entry = ResearchWatchlistEntry.create!(user: user, security: sec, source: "assistant", expires_at: 2.days.from_now)

    entry.keep!

    assert_nil entry.reload.expires_at
    assert_equal 0, ResearchWatchlistEntry.where(id: entry.id).expired.count
  end
end
