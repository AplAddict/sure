require "test_helper"

class InvestmentNewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    @owner = users(:family_admin)
    @member = users(:family_member)
    @owned = @owner.family.accounts.create!(name: "News owner", balance: 100, cash_balance: 0, currency: "USD", owner: @owner, status: "active", accountable: Investment.new)
    @private = @owner.family.accounts.create!(name: "Private news", balance: 100, cash_balance: 0, currency: "USD", owner: @owner, status: "active", accountable: Investment.new)
    own_security = Security.create!(ticker: "OWNNW", exchange_mic: "XNAS", name: "Owned News")
    secret_security = Security.create!(ticker: "SECNW", exchange_mic: "XNAS", name: "Secret News")
    @owned.holdings.create!(security: own_security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD")
    @private.holdings.create!(security: secret_security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD")
    SecurityResearchSnapshot.create!(security: own_security, status: "current", generated_at: Time.current, imported_at: Time.current, payload: { "news" => [ { "title" => "Owned headline", "link" => "https://example.com/owned", "source" => "Wire", "published" => "2026-10-12", "tickers" => [ "OWNNW" ] } ] })
    SecurityResearchSnapshot.create!(security: secret_security, status: "current", generated_at: Time.current, imported_at: Time.current, payload: { "news" => [ { "title" => "Private headline", "link" => "https://example.com/private", "source" => "Wire", "published" => "2026-10-12", "tickers" => [ "SECNW" ] } ] })
  end

  test "shows only cached news for securities in accounts the member can access" do
    sign_in @owner
    get investment_news_path
    assert_response :success
    assert_match "Owned headline", response.body
    assert_match "Private headline", response.body

    sign_in @member
    get investment_news_path
    assert_response :success
    assert_no_match "Owned headline", response.body
    assert_no_match "Private headline", response.body
  end

  test "turbo request returns the investment workspace frame with its tab current" do
    sign_in @owner
    get investment_news_path, headers: { "Turbo-Frame" => "investment_workspace" }
    assert_response :success
    assert_select "turbo-frame#investment_workspace"
    assert_select "a[aria-current=page]", text: "News"
  end
end
