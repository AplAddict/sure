require "test_helper"

class InvestmentIncomesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @owner = users(:family_admin)
    @account = @owner.family.accounts.create!(name: "Income Page Brokerage", balance: 1000, cash_balance: 0, currency: "USD", owner: @owner, accountable: Investment.new)
    @account.entries.create!(name: "Dividend", amount: -42, date: Date.current, currency: "USD", entryable: Transaction.new(investment_activity_label: "Dividend"))
  end

  test "requires authentication" do
    get investment_income_path
    assert_redirected_to new_session_path
  end

  test "shows labeled income separated from cash flows and marks unsourced items unavailable" do
    sign_in @owner
    get investment_income_path

    assert_response :success
    assert_match "Income &amp; Performance", response.body
    assert_match "$42.00", response.body
    assert_match "Net option premium", response.body
    assert_match "Unavailable", response.body
    assert_no_match(/No verified premium label/, response.body)
    assert_match "Collected (sold to open)", response.body
  end

  test "shows volatility and max drawdown as unavailable without enough daily balances" do
    sign_in @owner
    get investment_income_path

    assert_response :success
    assert_match I18n.t("investment_incomes.show.volatility"), response.body
    assert_match I18n.t("investment_incomes.show.max_drawdown"), response.body
    reason = I18n.t("investment_incomes.show.risk_unavailable_reasons.non_contiguous_history")
    assert_select "span[title=?]", reason, count: 2
  end

  test "a member without access sees none of the owner's income" do
    sign_in users(:empty)
    get investment_income_path

    assert_response :success
    assert_no_match "$42.00", response.body
  end

  test "all period ignores activity in another member's private account" do
    accessible_date = 2.years.ago.to_date
    private_date = 8.years.ago.to_date
    @account.entries.create!(name: "Accessible trade", amount: 10, date: accessible_date, currency: "USD", entryable: Trade.new(security: securities(:aapl), qty: 1, price: 10, currency: "USD"))
    private_account = @owner.family.accounts.create!(name: "Other member private", balance: 10, currency: "USD", owner: users(:family_member), accountable: Investment.new)
    private_account.entries.create!(name: "Private trade", amount: 10, date: private_date, currency: "USD", entryable: Trade.new(security: securities(:aapl), qty: 1, price: 10, currency: "USD"))

    sign_in @owner
    get investment_income_path(period: "all_time")

    assert_response :success
    assert_match I18n.l(accessible_date - 1.month), response.body
    assert_no_match I18n.l(private_date - 1.month), response.body
  end

  test "falls back to the default period for an unknown period type" do
    sign_in @owner
    get investment_income_path(period: "bogus")
    assert_response :success
  end
end
