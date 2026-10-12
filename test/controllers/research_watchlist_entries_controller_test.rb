require "test_helper"

class ResearchWatchlistEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:family_admin)
    @member = users(:family_member)
    @security = Security.create!(ticker: "QUEUE#{SecureRandom.hex(3)}", exchange_mic: "XNAS", name: "Queue Test")
    @entry = ResearchWatchlistEntry.create!(user: @owner, security: @security, status: "researching", priority: 2, thesis: "Owner-only thesis")
  end

  test "shows only the signed-in user's thesis queue" do
    sign_in @owner
    get research_watchlist_entries_path

    assert_response :success
    assert_match "Owner-only thesis", response.body
    assert_match @security.ticker, response.body
  end

  test "does not expose another family member's thesis queue" do
    sign_in @member
    get research_watchlist_entries_path

    assert_response :success
    assert_no_match "Owner-only thesis", response.body
    assert_no_match @security.ticker, response.body
  end

  test "creates an entry for a known ticker for the signed-in user only" do
    other = Security.create!(ticker: "ADD#{SecureRandom.hex(3)}", exchange_mic: "XNAS", name: "Add Test")
    sign_in @owner

    assert_difference -> { @owner.research_watchlist_entries.count }, 1 do
      assert_no_difference -> { @member.research_watchlist_entries.count } do
        post research_watchlist_entries_path, params: { research_watchlist_entry: { ticker: other.ticker, status: "watching", priority: 1, thesis: "Check margins" } }
      end
    end

    assert_redirected_to research_watchlist_entries_path
  end

  test "rejects an unknown ticker without creating a placeholder or entry" do
    sign_in @owner

    assert_no_difference [ "ResearchWatchlistEntry.count", "Security.count" ] do
      post research_watchlist_entries_path, params: { research_watchlist_entry: { ticker: "NOPE#{SecureRandom.hex(3)}", status: "watching", priority: 3 } }
    end

    assert_response :unprocessable_entity
  end

  test "updates only the owner's entry" do
    sign_in @owner
    patch research_watchlist_entry_path(@entry), params: { research_watchlist_entry: { status: "ready", priority: 1, thesis: "Updated" } }

    assert_redirected_to research_watchlist_entries_path
    assert_equal "ready", @entry.reload.status
    assert_equal "Updated", @entry.thesis
  end

  test "another user cannot update or delete an entry" do
    sign_in @member

    patch research_watchlist_entry_path(@entry), params: { research_watchlist_entry: { status: "archived" } }
    assert_response :not_found
    delete research_watchlist_entry_path(@entry)
    assert_response :not_found

    assert_equal "researching", @entry.reload.status
  end

  test "owner can remove an entry" do
    sign_in @owner

    assert_difference -> { @owner.research_watchlist_entries.count }, -1 do
      delete research_watchlist_entry_path(@entry)
    end
  end
end
