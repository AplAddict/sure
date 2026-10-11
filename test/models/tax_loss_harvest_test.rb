require "test_helper"

class TaxLossHarvestTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    @today = Date.new(2026, 10, 11)
    @owner = users(:family_admin)
    @other_member = users(:family_member)
    @family = @owner.family

    # Isolated accounts so fixture holdings never leak into assertions.
    @taxable = create_investment("Harvest Brokerage", subtype: "brokerage", owner: @owner)
    @ira = create_investment("Harvest IRA", subtype: "ira", owner: @owner)
    @loss_security = Security.create!(ticker: "TLHLOSS", exchange_mic: "XNAS")
    @gain_security = Security.create!(ticker: "TLHGAIN", exchange_mic: "XNAS")
  end

  test "lists unrealized losses with cost basis, loss percent and candidate flag" do
    hold(@taxable, @loss_security, qty: 10, price: 80, cost_basis: 100)
    hold(@taxable, @gain_security, qty: 10, price: 120, cost_basis: 100)

    result = harvest(@owner)

    assert_equal [ "TLHLOSS" ], result.rows.map(&:ticker)
    row = result.rows.first
    assert_equal BigDecimal("-200"), row.loss.amount
    assert_equal BigDecimal("-20.0"), row.loss_pct
    assert row.candidate
    assert_equal BigDecimal("800"), row.market_value.amount
    assert_equal BigDecimal("1000"), row.cost_basis.amount
    assert_equal 1, result.totals.candidate_count
    assert_equal BigDecimal("200"), result.totals.loss.amount
  end

  test "small losses are listed but not candidates" do
    hold(@taxable, @loss_security, qty: 10, price: 98, cost_basis: 100)

    row = harvest(@owner).rows.first

    assert_not row.candidate
    assert_equal 0, harvest(@owner).totals.candidate_count
  end

  test "unknown cost basis is unavailable and never counted as a loss or zero" do
    hold(@taxable, @loss_security, qty: 10, price: 80, cost_basis: nil)

    result = harvest(@owner)

    assert_empty result.rows
    assert_equal [ :cost_basis_unknown ], result.unavailable.map(&:reason)
    assert_equal BigDecimal("0"), result.totals.loss.amount
    assert_equal 0, result.totals.loss_count
  end

  test "foreign currency value without a stored rate is unavailable not zero" do
    eur_account = @family.accounts.create!(
      name: "Harvest EUR Brokerage", balance: 10_000, cash_balance: 0, currency: "EUR", owner: @owner,
      status: "active", accountable: Investment.new(subtype: "brokerage")
    )
    hold(eur_account, @loss_security, qty: 10, price: 80, cost_basis: 100, currency: "EUR")
    Money.any_instance.stubs(:exchange_to).raises(Money::ConversionError.new(from_currency: "EUR", to_currency: "USD", date: @today))

    result = harvest(@owner)

    assert_empty result.rows
    assert_equal [ :exchange_rate_missing ], result.unavailable.map(&:reason)
    assert_equal BigDecimal("0"), result.totals.loss.amount
  end

  test "tax advantaged accounts are excluded and counted" do
    hold(@taxable, @loss_security, qty: 10, price: 80, cost_basis: 100)
    hold(@ira, @gain_security, qty: 10, price: 50, cost_basis: 100)

    result = harvest(@owner)

    assert_equal [ "TLHLOSS" ], result.rows.map(&:ticker)
    assert_not_includes result.accounts.map(&:id), @ira.id
    assert_operator result.excluded_account_count, :>=, 1
  end

  test "only the signed-in user's accessible accounts are used" do
    hold(@taxable, @loss_security, qty: 10, price: 80, cost_basis: 100)

    assert_equal [ "TLHLOSS" ], harvest(@owner).rows.map(&:ticker)
    assert_empty harvest(@other_member).rows
    assert_empty harvest(@other_member).unavailable
    assert_empty harvest(users(:empty)).rows
  end

  test "an account shared with another member becomes visible to that member only" do
    hold(@taxable, @loss_security, qty: 10, price: 80, cost_basis: 100)
    AccountShare.create!(account: @taxable, user: @other_member, permission: "read_only", include_in_finances: true)

    assert_equal [ "TLHLOSS" ], harvest(@other_member).rows.map(&:ticker)
    assert_empty harvest(users(:empty)).rows
  end

  test "holding period is long term when every lot is over a year old" do
    hold(@taxable, @loss_security, qty: 10, price: 80, cost_basis: 100)
    create_trade(@loss_security, account: @taxable, qty: 10, date: @today - 400, price: 100)

    row = harvest(@owner).rows.first

    assert_equal :long, row.term
    assert_equal BigDecimal("10"), row.long_term_qty
    assert_equal BigDecimal("0"), row.short_term_qty
    assert_equal @today - 400, row.first_acquired
  end

  test "a sale consumes the oldest lot first so the remaining shares can be short term" do
    hold(@taxable, @loss_security, qty: 10, price: 80, cost_basis: 100)
    create_trade(@loss_security, account: @taxable, qty: 10, date: @today - 500, price: 100)
    create_trade(@loss_security, account: @taxable, qty: 10, date: @today - 40, price: 100)
    create_trade(@loss_security, account: @taxable, qty: -10, date: @today - 20, price: 90)

    row = harvest(@owner).rows.first

    assert_equal :short, row.term
    assert_equal BigDecimal("10"), row.short_term_qty
    assert_equal @today - 40, row.first_acquired
  end

  test "holding period is mixed when lots straddle one year" do
    hold(@taxable, @loss_security, qty: 15, price: 80, cost_basis: 100)
    create_trade(@loss_security, account: @taxable, qty: 5, date: @today - 450, price: 100)
    create_trade(@loss_security, account: @taxable, qty: 10, date: @today - 40, price: 100)

    row = harvest(@owner).rows.first

    assert_equal :mixed, row.term
    assert_equal BigDecimal("5"), row.long_term_qty
    assert_equal BigDecimal("10"), row.short_term_qty
  end

  test "holding period is unknown when recorded trades do not account for the quantity" do
    hold(@taxable, @loss_security, qty: 10, price: 80, cost_basis: 100)
    create_trade(@loss_security, account: @taxable, qty: 4, date: @today - 400, price: 100)

    row = harvest(@owner).rows.first

    assert_equal :unknown, row.term
    assert_nil row.first_acquired
    assert_equal BigDecimal("0"), harvest(@owner).totals.short_term_loss.amount
    assert_equal BigDecimal("200"), harvest(@owner).totals.unknown_term_loss.amount
  end

  test "a purchase in the last 30 days is flagged as a wash-sale risk" do
    hold(@taxable, @loss_security, qty: 10, price: 80, cost_basis: 100)
    create_trade(@loss_security, account: @taxable, qty: 10, date: @today - 10, price: 100)

    flag = harvest(@owner).rows.first.wash_flags.find { |f| f.kind == :recent_purchase }

    assert flag
    assert_equal @today - 10, flag.date
    assert_equal BigDecimal("10"), flag.detail
  end

  test "holding the same security in another visible account is flagged including tax advantaged ones" do
    hold(@taxable, @loss_security, qty: 10, price: 80, cost_basis: 100)
    hold(@ira, @loss_security, qty: 3, price: 80, cost_basis: 100)

    flag = harvest(@owner).rows.first.wash_flags.find { |f| f.kind == :held_elsewhere }

    assert flag
    assert_equal [ "Harvest IRA" ], flag.detail
  end

  test "another member's accounts never appear in wash-sale flags" do
    hold(@taxable, @loss_security, qty: 10, price: 80, cost_basis: 100)
    other_account = create_investment("Private Brokerage", subtype: "brokerage", owner: @other_member)
    hold(other_account, @loss_security, qty: 99, price: 80, cost_basis: 100)

    flags = harvest(@owner).rows.first.wash_flags

    assert_empty flags.select { |f| f.kind == :held_elsewhere }
  end

  test "realized year to date counts only the user's taxable sales and separates unknowns" do
    hold(@taxable, @gain_security, qty: 5, price: 150, cost_basis: 100, date: @today - 30)
    create_trade(@gain_security, account: @taxable, qty: -5, date: @today - 5, price: 150)

    result = harvest(@owner).realized_year_to_date

    assert_equal 1, result[:known] + result[:unknown]
    assert_equal 0, harvest(@other_member).realized_year_to_date[:known] + harvest(@other_member).realized_year_to_date[:unknown]
  end

  private
    def harvest(user)
      TaxLossHarvest.new(user: user, today: @today)
    end

    def create_investment(name, subtype:, owner:)
      @family.accounts.create!(
        name: name, balance: 10_000, cash_balance: 0, currency: "USD", owner: owner, status: "active",
        accountable: Investment.new(subtype: subtype)
      )
    end

    def hold(account, security, qty:, price:, cost_basis:, currency: "USD", date: @today)
      account.holdings.create!(
        security: security, date: date, qty: qty, price: price, amount: qty * price,
        currency: currency, cost_basis: cost_basis, cost_basis_source: (cost_basis ? "provider" : nil)
      )
    end
end
