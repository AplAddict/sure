require "test_helper"

class SnaptradeAccountTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family_a = families(:dylan_family)
    @family_b = families(:empty)

    @item_a = SnaptradeItem.create!(
      family: @family_a,
      name: "Family A Broker",
      client_id: "client_a",
      consumer_key: "key_a",
      status: "good"
    )

    @item_b = SnaptradeItem.create!(
      family: @family_b,
      name: "Family B Broker",
      client_id: "client_b",
      consumer_key: "key_b",
      status: "good"
    )
  end

  test "option positions expose only reviewed contract fields and preserve unknown values" do
    account = SnaptradeAccount.new(snaptrade_item: @item_a, name: "Brokerage", currency: "USD", raw_options_payload: [
      {
        "instrument" => { "symbol" => "MSFT  270115C00500000", "option_type" => "CALL", "expiration_date" => "2027-01-15", "strike_price" => "500" },
        "units" => "2", "price" => "12.5", "currency" => { "code" => "USD" }, "untrusted_provider_detail" => "do not expose"
      },
      { "instrument" => { "symbol" => "bad contract" }, "units" => "not-a-number" }
    ])

    positions = account.option_positions_snapshot

    assert_equal 2, positions.size
    assert_equal "MSFT  270115C00500000", positions.first.contract
    assert_equal "MSFT", positions.first.underlying
    assert_equal "CALL", positions.first.type
    assert_equal Date.new(2027, 1, 15), positions.first.expiration
    assert_equal BigDecimal("500"), positions.first.strike
    assert_equal BigDecimal("2"), positions.first.quantity
    assert_equal BigDecimal("12.5"), positions.first.mark
    assert_equal "USD", positions.first.currency
    assert_nil positions.last.expiration
    assert_nil positions.last.quantity
  end

  test "option gain and loss uses the broker's per-share cost basis, units and multiplier" do
    account = SnaptradeAccount.new(snaptrade_item: @item_a, name: "Brokerage", currency: "USD", raw_options_payload: [
      { "instrument" => { "symbol" => "ACHR  261016C00007000", "option_type" => "CALL", "expiration_date" => "2026-10-16", "strike_price" => "7", "multiplier" => "100" },
        "units" => "-1", "price" => "0.01", "cost_basis" => "0.1634", "currency" => "USD" },
      { "instrument" => { "symbol" => "GME   261120C00031000", "option_type" => "CALL", "expiration_date" => "2026-11-20", "strike_price" => "31", "multiplier" => "100" },
        "units" => "1", "price" => "1.16", "cost_basis" => "0.6766", "currency" => "USD" },
      { "instrument" => { "symbol" => "NVDA  261113P00215000", "option_type" => "PUT", "expiration_date" => "2026-11-13", "strike_price" => "215", "multiplier" => "100" },
        "units" => "-1", "price" => "3.13", "cost_basis" => "2.1434", "currency" => "USD" }
    ])

    short_winner, long_winner, short_loser = account.option_positions_snapshot

    assert_equal BigDecimal("16.34"), short_winner.cost_total
    assert_equal BigDecimal("15.34"), short_winner.gain
    assert_in_delta 93.88, short_winner.gain_pct, 0.01
    assert_equal BigDecimal("67.66"), long_winner.cost_total
    assert_equal BigDecimal("48.34"), long_winner.gain
    assert_in_delta(-98.66, short_loser.gain, 0.001)
  end

  test "option gain and loss is unavailable rather than zero when any input is missing" do
    account = SnaptradeAccount.new(snaptrade_item: @item_a, name: "Brokerage", currency: "USD", raw_options_payload: [
      { "instrument" => { "symbol" => "AAPL  270115C00250000", "multiplier" => "100" }, "units" => "1", "price" => "2", "currency" => "USD" },
      { "instrument" => { "symbol" => "MSFT  270115C00500000" }, "units" => "1", "price" => "2", "cost_basis" => "1", "currency" => "USD" },
      { "instrument" => { "symbol" => "TSLA  270115C00300000", "multiplier" => "100" }, "units" => "1", "cost_basis" => "1", "currency" => "USD" },
      { "instrument" => { "symbol" => "NFLX  270115C00900000", "multiplier" => "100" }, "units" => "1", "price" => "2", "cost_basis" => "0", "currency" => "USD" }
    ])

    no_cost, no_multiplier, no_mark, zero_cost = account.option_positions_snapshot

    [ no_cost, no_multiplier, no_mark ].each do |position|
      assert_nil position.gain
      assert_nil position.gain_pct
    end
    assert_equal BigDecimal("200"), zero_cost.gain
    assert_nil zero_cost.gain_pct
  end

  test "same snaptrade_account_id can be linked under different snaptrade_items" do
    SnaptradeAccount.create!(
      snaptrade_item: @item_a,
      snaptrade_account_id: "shared_snap_uuid_1",
      name: "IRA",
      currency: "USD",
      current_balance: 5000
    )

    assert_difference "SnaptradeAccount.count", 1 do
      SnaptradeAccount.create!(
        snaptrade_item: @item_b,
        snaptrade_account_id: "shared_snap_uuid_1",
        name: "IRA",
        currency: "USD",
        current_balance: 5000
      )
    end
  end

  test "same snaptrade_account_id cannot appear twice under the same snaptrade_item" do
    SnaptradeAccount.create!(
      snaptrade_item: @item_a,
      snaptrade_account_id: "dup_snap_uuid",
      name: "Brokerage",
      currency: "USD",
      current_balance: 1000
    )

    duplicate = SnaptradeAccount.new(
      snaptrade_item: @item_a,
      snaptrade_account_id: "dup_snap_uuid",
      name: "Brokerage",
      currency: "USD",
      current_balance: 1000
    )
    refute duplicate.valid?
    assert_includes duplicate.errors[:snaptrade_account_id], "has already been taken"

    assert_raises(ActiveRecord::RecordInvalid) do
      SnaptradeAccount.create!(
        snaptrade_item: @item_a,
        snaptrade_account_id: "dup_snap_uuid",
        name: "Brokerage",
        currency: "USD",
        current_balance: 1000
      )
    end
  end

  test "suggested_account_type maps SnapTrade account categories" do
    account = SnaptradeAccount.new(snaptrade_item: @item_a, name: "Account", currency: "USD")

    account.raw_payload = { "account_category" => "DEPOSIT" }
    assert_equal "Depository", account.suggested_account_type

    account.raw_payload = { "account_category" => "LOC", "raw_type" => "line_of_credit" }
    assert_equal "Loan", account.suggested_account_type

    account.raw_payload = { "account_category" => "LOC", "raw_type" => "CREDIT_CARD" }
    assert_equal "CreditCard", account.suggested_account_type

    account.raw_payload = { "account_category" => "INVESTMENT" }
    assert_equal "Investment", account.suggested_account_type

    account.raw_payload = { "account_category" => "INVESTMENT", "raw_type" => "CRYPTOCURRENCY" }
    assert_equal "Crypto", account.suggested_account_type

    account.raw_payload = {}
    assert_equal "Investment", account.suggested_account_type
  end

  # Regression: the after_destroy callback enqueues SnaptradeConnectionCleanupJob,
  # which references the account/item by id. If it is enqueued before the destroy
  # transaction commits (Rails 8.1's immediate-enqueue default), a worker can run
  # before COMMIT: its "do other accounts still share this authorization?" guard
  # then sees the not-yet-deleted row, skips the provider call, and leaks the
  # SnapTrade connection. Enqueuing must be deferred until commit.
  test "connection cleanup job is deferred until the destroy transaction commits" do
    account = SnaptradeAccount.create!(
      snaptrade_item: @item_a,
      snaptrade_account_id: "cleanup_uuid",
      snaptrade_authorization_id: "auth_cleanup",
      name: "Brokerage",
      currency: "USD",
      current_balance: 1000
    )

    enqueued_mid_transaction = nil

    ActiveRecord::Base.transaction do
      account.destroy!
      enqueued_mid_transaction = enqueued_jobs.any? { |job| job[:job] == SnaptradeConnectionCleanupJob }
    end

    assert_not enqueued_mid_transaction,
      "SnaptradeConnectionCleanupJob was enqueued before the destroy committed (would race COMMIT and leak the provider connection)"
    assert_enqueued_with job: SnaptradeConnectionCleanupJob
  end
end
