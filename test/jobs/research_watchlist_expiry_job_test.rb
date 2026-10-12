require "test_helper"

class ResearchWatchlistExpiryJobTest < ActiveJob::TestCase
  test "removes expired assistant entries and nothing else" do
    user = users(:family_admin)
    make = ->(**attrs) { ResearchWatchlistEntry.create!(user: user, security: Security.create!(ticker: Array.new(5) { ("A".."Z").to_a.sample }.join, exchange_mic: "XNAS", name: "Job"), **attrs) }
    expired = make.call(source: "assistant", expires_at: 1.day.ago)
    live = make.call(source: "assistant", expires_at: 1.day.from_now)
    mine = make.call(source: "user")

    ResearchWatchlistExpiryJob.perform_now

    assert_not ResearchWatchlistEntry.exists?(expired.id)
    assert ResearchWatchlistEntry.exists?(live.id)
    assert ResearchWatchlistEntry.exists?(mine.id)
  end

  test "is scheduled daily" do
    schedule = YAML.load_file(Rails.root.join("config/schedule.yml"))
    entry = schedule.values.find { |job| job["class"] == "ResearchWatchlistExpiryJob" }

    assert entry, "ResearchWatchlistExpiryJob must be in config/schedule.yml"
    assert_equal "scheduled", entry["queue"]
  end
end
