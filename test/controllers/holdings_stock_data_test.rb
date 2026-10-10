require "test_helper"

class HoldingsStockDataTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @holding = Holding.joins(:account).where(accounts: { family_id: users(:family_admin).family_id }).where("qty > 0").first
  end

  test "shows a not-loaded message instead of zeros when no data is cached" do
    skip "no fixture holding" unless @holding

    get holding_path(@holding)

    assert_response :success
    assert_select "[data-testid=stock-data-unavailable]"
  end

  test "shows cached figures with unavailable placeholders for missing ones" do
    skip "no fixture holding" unless @holding
    SecurityFundamental.create!(security: @holding.security, fetched_at: Time.current,
                                payload: { "trailing_pe" => 38.6, "recommendation" => "buy" })

    get holding_path(@holding)

    assert_response :success
    assert_select "[data-testid=stock-data]" do
      assert_select "dd", text: "38.60"
      assert_select "dd", text: "Buy"
      assert_select "dd", text: "Unavailable"
    end
  end
end
