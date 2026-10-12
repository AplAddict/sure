require "test_helper"

class Assistant::Function::AddToResearchWatchlistTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @other = users(:family_member)
    @security = Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Assistant Add Co")
    @fn = Assistant::Function::AddToResearchWatchlist.new(@user)
  end

  # Distinct 5-letter symbols so tests never collide with fixture securities.
  def letters_ticker
    loop do
      candidate = Array.new(5) { ("A".."Z").to_a.sample }.join
      return candidate unless Security.exists?(ticker: candidate)
    end
  end

  def enable!(user = @user)
    user.update!(preferences: (user.preferences || {}).merge("ai_watchlist_enabled" => true))
  end

  test "is offered to the assistant only when the member turned the setting on" do
    assert_not_includes Assistant.function_classes(@user), Assistant::Function::AddToResearchWatchlist
    enable!
    assert_includes Assistant.function_classes(@user.reload), Assistant::Function::AddToResearchWatchlist
    assert_not_includes Assistant.function_classes(@other), Assistant::Function::AddToResearchWatchlist
    assert_not_includes Assistant.mcp_read_function_classes(@user), Assistant::Function::AddToResearchWatchlist
  end

  test "refuses to run when the setting is off, even if called directly" do
    assert_no_difference -> { ResearchWatchlistEntry.count } do
      result = @fn.call("ticker" => @security.ticker)
      assert_equal false, result[:success]
      assert_equal "setting_disabled", result[:error]
    end
  end

  test "adds a known ticker for the calling member only and labels it as assistant-added" do
    enable!

    assert_difference -> { @user.research_watchlist_entries.count }, 1 do
      assert_no_difference -> { @other.research_watchlist_entries.count } do
        result = @fn.call("ticker" => @security.ticker.downcase, "thesis" => "Check margins", "priority" => 2)
        assert result[:success], result.inspect
      end
    end

    entry = @user.research_watchlist_entries.find_by!(security: @security)
    assert_equal "assistant", entry.source
    assert_equal "watching", entry.status
    assert_equal 2, entry.priority
    assert_equal "Check margins", entry.thesis
  end

  test "assistant entries expire after the member's chosen number of days, 30 by default" do
    enable!
    freeze_time do
      assert @fn.call("ticker" => @security.ticker)[:success]
      assert_in_delta 30.days.from_now.to_f, @user.research_watchlist_entries.find_by!(security: @security).expires_at.to_f, 2
    end

    other = Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Seven Day")
    @user.update!(preferences: @user.preferences.merge("ai_watchlist_expiry_days" => 7))
    freeze_time do
      assert Assistant::Function::AddToResearchWatchlist.new(@user.reload).call("ticker" => other.ticker)[:success]
      assert_in_delta 7.days.from_now.to_f, @user.research_watchlist_entries.find_by!(security: other).expires_at.to_f, 2
    end
  end

  test "an expired leftover does not block adding the same ticker again" do
    enable!
    ResearchWatchlistEntry.create!(user: @user, security: @security, source: "assistant", expires_at: 1.hour.ago, thesis: "stale")

    result = @fn.call("ticker" => @security.ticker, "thesis" => "fresh")

    assert result[:success], result.inspect
    entry = @user.research_watchlist_entries.find_by!(security: @security)
    assert_equal "fresh", entry.thesis
    assert entry.expires_at > Time.current
  end

  test "never overwrites an entry the member already has" do
    enable!
    mine = ResearchWatchlistEntry.create!(user: @user, security: @security, status: "ready", priority: 1, thesis: "My own thesis")

    result = @fn.call("ticker" => @security.ticker, "thesis" => "Assistant rewrite", "priority" => 5)

    assert_equal false, result[:success]
    assert_equal "already_on_watchlist", result[:error]
    mine.reload
    assert_equal "My own thesis", mine.thesis
    assert_equal 1, mine.priority
    assert_equal "user", mine.source
  end

  test "rejects bad tickers and unknown tickers without creating anything" do
    enable!
    provider = mock("yahoo")
    provider.stubs(:search_securities).returns(Struct.new(:success?, :data).new(true, []))
    Provider::YahooFinance.stubs(:new).returns(provider)

    assert_no_difference -> { ResearchWatchlistEntry.count } do
      assert_no_difference -> { Security.count } do
        assert_equal "invalid_ticker", @fn.call("ticker" => "not a ticker!")[:error]
        assert_equal "unknown_ticker", @fn.call("ticker" => "ZZQQX")[:error]
      end
    end
  end

  test "caps how many entries the assistant can add per day" do
    enable!
    ResearchWatchlistEntry::ASSISTANT_ADDS_PER_DAY.times do
      sec = Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Cap Co")
      ResearchWatchlistEntry.create!(user: @user, security: sec, source: "assistant")
    end

    result = @fn.call("ticker" => @security.ticker)

    assert_equal false, result[:success]
    assert_equal "daily_limit", result[:error]
    assert_nil @user.research_watchlist_entries.find_by(security: @security)
  end

  test "a member's own manual adds do not use up the assistant's daily allowance" do
    enable!
    ResearchWatchlistEntry::ASSISTANT_ADDS_PER_DAY.times do
      sec = Security.create!(ticker: letters_ticker, exchange_mic: "XNAS", name: "Manual Co")
      ResearchWatchlistEntry.create!(user: @user, security: sec, source: "user")
    end

    assert @fn.call("ticker" => @security.ticker)[:success]
  end

  test "definition describes the tool and requires a ticker" do
    definition = @fn.to_definition
    assert_equal "add_to_research_watchlist", definition[:name]
    assert_includes definition[:params_schema][:required], "ticker"
    assert_match(/research/i, definition[:description])
  end
end
