require "test_helper"

class TaxLotReviewTest < ActiveSupport::TestCase
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @today = Date.new(2026, 10, 12)
  end

  test "splits each broker lot into short and long term by holding period and totals them" do
    account = taxable_account
    security = Security.create!(ticker: "TLRA", exchange_mic: "XNAS", name: "Lot Review")
    holding(account, security, qty: 30)
    stub_lots(account, "TLRA", [
      lot(10, 1000, 1500, @today - 400.days),  # long-term gain +500
      lot(10, 1000, 700, @today - 400.days),   # long-term loss  -300
      lot(10, 1000, 1200, @today - 30.days)    # short-term gain +200
    ])

    review = TaxLotReview.new(user: @user, today: @today)

    assert_equal BigDecimal("500"), review.totals[:long_gain]
    assert_equal BigDecimal("300"), review.totals[:long_loss]
    assert_equal BigDecimal("200"), review.totals[:short_gain]
    assert_equal BigDecimal("0"), review.totals[:short_loss]
    assert_equal 3, review.lots.size
  end

  test "reports days until a short-term lot turns long-term and lists only those inside the window" do
    account = taxable_account
    security = Security.create!(ticker: "TLRB", exchange_mic: "XNAS", name: "Soon Long")
    holding(account, security, qty: 20)
    stub_lots(account, "TLRB", [
      lot(10, 1000, 1400, @today - 350.days),  # long term in 16 days (held >365 days from day 366)
      lot(10, 1000, 1400, @today - 100.days)   # far away
    ])

    review = TaxLotReview.new(user: @user, today: @today, window_days: 60)

    approaching = review.approaching_long_term
    assert_equal 1, approaching.size
    assert_equal 16, approaching.first.days_to_long_term
    assert_equal BigDecimal("400"), approaching.first.gain
  end

  test "a lot held exactly 365 days is still short-term and turns long-term tomorrow" do
    account = taxable_account
    security = Security.create!(ticker: "TLRC", exchange_mic: "XNAS", name: "Boundary")
    holding(account, security, qty: 10)
    stub_lots(account, "TLRC", [ lot(10, 1000, 1100, @today - 365.days) ])

    boundary = TaxLotReview.new(user: @user, today: @today).lots.first

    assert_equal :short, boundary.term
    assert_equal 1, boundary.days_to_long_term
  end

  test "lots without an acquisition date or basis are counted as unmeasured, never as zero" do
    account = taxable_account
    security = Security.create!(ticker: "TLRD", exchange_mic: "XNAS", name: "Unknown")
    holding(account, security, qty: 20)
    stub_lots(account, "TLRD", [
      lot(10, 1000, 1500, nil),
      lot(10, nil, 1500, @today - 500.days)
    ])

    review = TaxLotReview.new(user: @user, today: @today)

    assert_equal 2, review.unmeasured_count
    assert_equal BigDecimal("0"), review.totals[:long_gain]
    assert_equal BigDecimal("0"), review.totals[:short_gain]
  end

  test "tax-advantaged accounts are excluded and counted" do
    ira = @family.accounts.create!(name: "Review IRA", balance: 1000, cash_balance: 0, currency: "USD", owner: @user, status: "active", accountable: Investment.new(subtype: "ira"))
    security = Security.create!(ticker: "TLRE", exchange_mic: "XNAS", name: "IRA Holding")
    holding(ira, security, qty: 10)
    stub_lots(ira, "TLRE", [ lot(10, 1000, 2000, @today - 500.days) ])

    review = TaxLotReview.new(user: @user, today: @today)

    assert_empty review.lots
    assert_equal 1, review.excluded_account_count
  end

  test "only the signed-in user's accessible accounts are reviewed" do
    account = taxable_account
    security = Security.create!(ticker: "TLRF", exchange_mic: "XNAS", name: "Private")
    holding(account, security, qty: 10)
    stub_lots(account, "TLRF", [ lot(10, 1000, 2000, @today - 500.days) ])

    assert_empty TaxLotReview.new(user: users(:empty), today: @today).lots
  end

  test "positions in a taxable account with no verified broker lots are counted, not silently omitted" do
    baseline = TaxLotReview.new(user: @user, today: @today).positions_without_lots
    account = taxable_account
    covered = Security.create!(ticker: "TLRG", exchange_mic: "XNAS", name: "Covered")
    uncovered = Security.create!(ticker: "TLRH", exchange_mic: "XNAS", name: "No Lots")
    holding(account, covered, qty: 10)
    holding(account, uncovered, qty: 5)
    stub_lots(account, "TLRG", [ lot(10, 1000, 1500, @today - 100.days) ])

    review = TaxLotReview.new(user: @user, today: @today)

    assert_equal 1, review.lots.size
    assert_equal baseline + 1, review.positions_without_lots
  end

  test "a lot is measured in its position's currency, not the account's" do
    account = taxable_account
    security = Security.create!(ticker: "TLRI", exchange_mic: "XNAS", name: "Foreign Pos")
    foreign_lot = PortfolioHoldings::Lot.new(acquired_on: @today - 100.days, quantity: BigDecimal("10"), cost_basis: BigDecimal("1000"), market_value: BigDecimal("1500"))
    position = PortfolioHoldings::Position.new(account: account, security: security, quantity: BigDecimal("10"), price: BigDecimal("150"), avg_cost: BigDecimal("100"),
                                               cost_basis: BigDecimal("1000"), market_value: BigDecimal("1500"), currency: "EUR", weight: nil, lots: [ foreign_lot ], day_change: nil)
    block = PortfolioHoldings::AccountBlock.new(account: account, positions: [ position ], market_value: BigDecimal("1500"), cost_basis: BigDecimal("1000"), cash: 0, currency: "USD")
    PortfolioHoldings.any_instance.stubs(:blocks).returns([ block ])
    PortfolioHoldings.any_instance.stubs(:accounts).returns([ account ])

    review = TaxLotReview.new(user: @user, today: @today)

    assert_empty review.lots
    assert_equal 1, review.unmeasured_count
  end

  test "an acquisition date in the future is unmeasured, not a negative holding period" do
    account = taxable_account
    security = Security.create!(ticker: "TLRJ", exchange_mic: "XNAS", name: "Future")
    holding(account, security, qty: 10)
    stub_lots(account, "TLRJ", [ lot(10, 1000, 1500, @today + 5.days) ])

    review = TaxLotReview.new(user: @user, today: @today)

    assert_empty review.lots
    assert_equal 1, review.unmeasured_count
  end

  test "long-term is judged by calendar anniversary, so a span containing Feb 29 does not flip a day early" do
    account = taxable_account
    security = Security.create!(ticker: "TLRK", exchange_mic: "XNAS", name: "Leap")
    holding(account, security, qty: 10)
    # 2023-03-01 to 2024-03-01 is 366 days (it contains Feb 29, 2024) but exactly one year.
    stub_lots(account, "TLRK", [ lot(10, 1000, 1100, Date.new(2023, 3, 1)) ])

    on_anniversary = TaxLotReview.new(user: @user, today: Date.new(2024, 3, 1)).lots.last
    day_after = TaxLotReview.new(user: @user, today: Date.new(2024, 3, 2)).lots.last

    assert_equal :short, on_anniversary.term
    assert_equal 1, on_anniversary.days_to_long_term
    assert_equal :long, day_after.term
    assert_nil day_after.days_to_long_term
  end

  private
    def taxable_account
      @family.accounts.create!(name: "Review Taxable #{SecureRandom.hex(3)}", balance: 5000, cash_balance: 0, currency: "USD", owner: @user,
                               status: "active", accountable: Investment.new(subtype: "brokerage"))
    end

    def holding(account, security, qty:)
      account.holdings.create!(security: security, date: Date.current, qty: qty, price: 100, amount: qty * 100, currency: "USD", cost_basis: 90, cost_basis_source: "provider")
    end

    def lot(quantity, basis, value, acquired)
      { "quantity" => quantity, "cost_basis" => basis, "current_value" => value, "original_purchase_date" => acquired&.iso8601 }
    end

    def stub_lots(account, ticker, lots)
      PortfolioHoldings.any_instance.stubs(:provider_lots).returns({ account.id => { ticker => lots.map(&:with_indifferent_access) } })
    end
end
