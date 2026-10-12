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
end
