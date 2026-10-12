require "test_helper"

class Holding::CurrentForInvestmentAccountsTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "Investment",
      balance: 2100,
      currency: "USD",
      accountable: Investment.new
    )
  end

  test "returns the latest provider import day while preserving per-security price dates" do
    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "USD")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    current_holding = create_holding("AAPL", date: Date.current, account_provider: account_provider)
    stale_holding = create_holding("STALE", date: 1.day.ago.to_date, account_provider: account_provider)
    older_price_current_holding = create_holding("MSFT", date: 1.day.ago.to_date, account_provider: account_provider)
    stale_holding.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)

    assert_equal [ current_holding.id, older_price_current_holding.id ].sort,
                 described_query.pluck(:id).sort
  end

  test "returns the latest holding per security for a manual account" do
    security = Security.create!(ticker: "AAPL", name: "Apple")
    create_holding_for_security(security, date: 2.days.ago.to_date, qty: 1)
    latest = create_holding_for_security(security, date: Date.current, qty: 2)

    assert_equal [ latest.id ], described_query.pluck(:id)
  end

  test "builds current holdings without per-row correlated subqueries" do
    sql = described_query.to_sql

    refute_includes sql, "NOT EXISTS"
    refute_match(/SELECT MAX\(provider_holdings\.updated_at::date\)/, sql)
  end

  test "selects provider and manual holdings independently when queried together" do
    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "USD")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)
    provider_holding = create_holding("AAPL", date: Date.current, account_provider: account_provider)

    manual_account = create_manual_account
    security = Security.create!(ticker: "MSFT", name: "MSFT")
    create_holding_for_security(security, date: 1.day.ago.to_date, account: manual_account)
    manual_latest = create_holding_for_security(security, date: Date.current, account: manual_account)

    assert_equal [ provider_holding.id, manual_latest.id ].sort,
                 described_query([ @account.id, manual_account.id ]).pluck(:id).sort
  end

  test "excludes foreign-currency holdings for a manual account" do
    security = Security.create!(ticker: "FOREIGN", name: "Foreign")
    usd_holding = create_holding_for_security(security, date: 1.day.ago.to_date)
    create_holding_for_security(security, date: Date.current, currency: "EUR")

    assert_equal [ usd_holding.id ], described_query.pluck(:id)
  end

  test "omits a security whose latest holding has zero quantity" do
    security = Security.create!(ticker: "CLOSED", name: "Closed")
    create_holding_for_security(security, date: 1.day.ago.to_date, qty: 5)
    create_holding_for_security(security, date: Date.current, qty: 0)

    assert_empty described_query.pluck(:id)
  end

  private
    def described_query(account_ids = [ @account.id ])
      Holding::CurrentForInvestmentAccounts.new(account_ids).relation
    end

    def create_manual_account
      @family.accounts.create!(
        name: "Manual investment",
        balance: 1000,
        currency: "USD",
        accountable: Investment.new
      )
    end

    def create_holding(ticker, date:, account_provider: nil)
      security = Security.create!(ticker: ticker, name: ticker)
      create_holding_for_security(security, date: date, account_provider: account_provider)
    end

    def create_holding_for_security(security, date:, qty: 1, currency: "USD", account: @account, account_provider: nil)
      account.holdings.create!(
        security: security,
        date: date,
        qty: qty,
        price: 100,
        amount: qty * 100,
        currency: currency,
        account_provider: account_provider
      )
    end
end
