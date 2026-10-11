require "test_helper"

class TaxLossHarvestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    @owner = users(:family_admin)
    @member = users(:family_member)
    @security = Security.create!(ticker: "TLHPAGE", exchange_mic: "XNAS", name: "Harvest Page Co")
    @account = @owner.family.accounts.create!(
      name: "Owner Only Brokerage", balance: 1000, cash_balance: 0, currency: "USD", owner: @owner,
      status: "active", accountable: Investment.new(subtype: "brokerage")
    )
    @account.holdings.create!(security: @security, date: Date.current, qty: 10, price: 80, amount: 800,
                              currency: "USD", cost_basis: 100, cost_basis_source: "provider")
  end

  test "owner sees their own loss positions" do
    sign_in @owner
    get tax_loss_harvest_path

    assert_response :success
    assert_select "td", text: /TLHPAGE/
    assert_match "Owner Only Brokerage", response.body
  end

  test "a family member without access sees nothing from another member's account" do
    sign_in @member
    get tax_loss_harvest_path

    assert_response :success
    assert_no_match(/TLHPAGE/, response.body)
    assert_no_match(/Owner Only Brokerage/, response.body)
  end

  test "requires authentication" do
    get tax_loss_harvest_path

    assert_redirected_to new_session_path
  end

  test "shows unavailable positions separately instead of as zero" do
    @account.holdings.create!(security: Security.create!(ticker: "TLHNOCB", exchange_mic: "XNAS"),
                              date: Date.current, qty: 5, price: 10, amount: 50, currency: "USD")
    sign_in @owner
    get tax_loss_harvest_path

    assert_response :success
    assert_match "TLHNOCB", response.body
    assert_match "Cost basis unknown", response.body
  end
end
