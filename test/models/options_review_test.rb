require "test_helper"

class OptionsReviewTest < ActiveSupport::TestCase
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    @owner = users(:family_admin)
    @account = @owner.family.accounts.create!(name: "Opt model", balance: 1000, cash_balance: 0, currency: "USD", owner: @owner, status: "active", accountable: Investment.new(subtype: "brokerage"))
    item = SnaptradeItem.create!(family: @owner.family, name: "Opt model broker", client_id: "om-client", consumer_key: "om-key", status: "good")
    @provider = SnaptradeAccount.create!(snaptrade_item: item, snaptrade_account_id: "om-account", name: "Opt model", currency: "USD", current_balance: 1000, last_holdings_sync: Time.current, raw_options_payload: [])
    AccountProvider.create!(account: @account, provider: @provider)
  end

  def contract(symbol, expiry, units: "1", price: "2", cost: "1")
    { "instrument" => { "symbol" => symbol, "option_type" => "PUT", "expiration_date" => expiry, "strike_price" => "100", "multiplier" => "100" }, "units" => units, "price" => price, "cost_basis" => cost, "currency" => { "code" => "USD" } }
  end

  def review(contracts, **opts)
    @provider.update!(raw_options_payload: contracts)
    OptionsReview.new(user: @owner, **opts)
  end

  test "sorts by expiry ascending by default with undated contracts last" do
    r = review([ contract("BBB  271217P00100000", "2027-12-17"), contract("AAA  261218P00100000", "2026-12-18"), contract("CCC  261120P00100000", nil) ])

    assert_equal %w[AAA BBB CCC], r.rows.map { |row| row.position.underlying }
  end

  test "descending keeps unmeasurable rows last too" do
    r = review([ contract("AAA  261218P00100000", "2026-12-18"), contract("BBB  271217P00100000", "2027-12-17"), contract("CCC  261120P00100000", nil) ], sort: "expiry", direction: "desc")

    assert_equal %w[BBB AAA CCC], r.rows.map { |row| row.position.underlying }
  end

  test "sorts by gain and puts contracts with no measurable gain last" do
    r = review([ contract("AAA  261218P00100000", "2026-12-18", price: "3", cost: "1"), contract("BBB  261218P00100000", "2026-12-18", price: nil, cost: "1"), contract("CCC  261218P00100000", "2026-12-18", price: "1.5", cost: "1") ], sort: "gain", direction: "desc")

    assert_equal %w[AAA CCC BBB], r.rows.map { |row| row.position.underlying }
  end

  test "an unknown sort or direction falls back safely" do
    r = review([ contract("AAA  261218P00100000", "2026-12-18") ], sort: "nonsense", direction: "sideways")

    assert_equal "expiry", r.sort
    assert_equal "asc", r.direction
  end

  test "groups by underlying and totals only when every contract is measured" do
    r = review([ contract("AAA  261218P00100000", "2026-12-18", price: "3", cost: "1"), contract("AAA  270115C00100000", "2027-01-15", price: "2", cost: "1"),
                 contract("BBB  261218P00100000", "2026-12-18", price: nil, cost: "1") ])

    aaa = r.groups.find { |g| g.underlying == "AAA" }
    bbb = r.groups.find { |g| g.underlying == "BBB" }
    assert_equal 2, aaa.rows.size
    assert_equal BigDecimal("300"), aaa.gain
    assert_nil bbb.gain
    assert_equal 1, bbb.unmeasured_count
    assert_nil r.total_gain
  end

  test "a measured zero is a real zero" do
    r = review([ contract("AAA  261218P00100000", "2026-12-18", price: "1", cost: "1") ])

    assert_equal BigDecimal("0"), r.groups.first.gain
    assert_equal BigDecimal("0"), r.total_gain
  end

  test "flags expiring-soon and expired contracts, not the ones further out or undated" do
    today = Date.current
    r = review([ contract("AAA  261218P00100000", (today + 3).iso8601), contract("BBB  261218P00100000", (today - 1).iso8601), contract("CCC  261218P00100000", (today + 30).iso8601), contract("DDD  261218P00100000", nil) ])

    assert_equal 1, r.expiring_soon_count
    assert_equal 1, r.expired_count
  end

  test "another member sees nothing of this account" do
    r = review([ contract("AAA  261218P00100000", "2026-12-18") ])
    assert_equal 1, r.rows.size
    assert_empty OptionsReview.new(user: users(:family_member)).rows
  end
end
