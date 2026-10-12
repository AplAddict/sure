require "test_helper"

class TaxLotReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    @owner = users(:family_admin)
    @account = @owner.family.accounts.create!(name: "Lot Page Brokerage", balance: 5000, cash_balance: 0, currency: "USD", owner: @owner,
                                              status: "active", accountable: Investment.new(subtype: "brokerage"))
    security = Security.create!(ticker: "LOTPG", exchange_mic: "XNAS", name: "Lot Page Co")
    @account.holdings.create!(security: security, date: Date.current, qty: 10, price: 150, amount: 1500, currency: "USD", cost_basis: 100, cost_basis_source: "provider")
    PortfolioHoldings.any_instance.stubs(:provider_lots).returns({
      @account.id => { "LOTPG" => [ { "quantity" => 10, "cost_basis" => 1000, "current_value" => 1500, "original_purchase_date" => (Date.current - 350.days).iso8601 }.with_indifferent_access ] }
    })
  end

  test "requires authentication" do
    get tax_lot_review_path
    assert_redirected_to new_session_path
  end

  test "shows lots by holding period with the days until long-term and no tax advice" do
    sign_in @owner
    get tax_lot_review_path

    assert_response :success
    assert_match "LOTPG", response.body
    assert_match "Short-term", response.body
    assert_match "$500.00", response.body
    assert_match "16 days", response.body
    assert_no_match(/you should|we recommend|estimated tax|tax due|sell now/i, response.body)
    assert_match "no tax owed, no advice", response.body
  end

  test "a member without access to the account sees none of its lots" do
    sign_in users(:empty)
    get tax_lot_review_path

    assert_response :success
    assert_no_match "LOTPG", response.body
  end
end
