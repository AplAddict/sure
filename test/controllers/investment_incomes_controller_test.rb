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
    assert_match "Option premium", response.body
    assert_match "Unavailable", response.body
  end

  test "a member without access sees none of the owner's income" do
    sign_in users(:empty)
    get investment_income_path

    assert_response :success
    assert_no_match "$42.00", response.body
  end

  test "falls back to the default period for an unknown period type" do
    sign_in @owner
    get investment_income_path(period: "bogus")
    assert_response :success
  end
end
