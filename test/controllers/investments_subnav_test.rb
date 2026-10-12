require "test_helper"

class InvestmentsSubnavTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    ensure_tailwind_build
    @owner = users(:family_admin)
    @owner.family.accounts.create!(name: "Subnav Brokerage", balance: 1000, cash_balance: 0, currency: "USD", owner: @owner,
                                   status: "active", accountable: Investment.new(subtype: "brokerage"))
    sign_in @owner
  end

  {
    portfolio_holdings: :holdings, investment_income: :income, tax_lot_review: :tax_lots,
    tax_loss_harvest: :harvest, options_review: :options, market_events: :events, research_watchlist_entries: :watchlist
  }.each do |route, key|
    test "#{route} shows the investments sub-navigation with itself marked current" do
      get public_send("#{route}_path")

      assert_response :success
      assert_select "nav[aria-label=?]", I18n.t("investments.subnav.label") do
        assert_select "a[aria-current=page]", text: I18n.t("investments.subnav.#{key}")
        assert_select "a", minimum: 8
      end
    end
  end
end
