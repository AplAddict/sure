class BalanceSheet
  include Monetizable

  monetize :net_worth

  attr_reader :family, :user

  def initialize(family, user: nil)
    @family = family
    @user = user || Current.user
  end

  def assets
    @assets ||= ClassificationGroup.new(
      classification: "asset",
      currency: family.currency,
      accounts: sorted(account_totals.asset_accounts)
    )
  end

  def liabilities
    @liabilities ||= ClassificationGroup.new(
      classification: "liability",
      currency: family.currency,
      accounts: sorted(account_totals.liability_accounts)
    )
  end

  def classification_groups
    [ assets, liabilities ]
  end

  def account_groups
    [ assets.account_groups, liabilities.account_groups ].flatten
  end

  def net_worth
    assets.total - liabilities.total
  end

  def net_worth_series(period: Period.last_30_days)
    net_worth_series_builder.net_worth_series(period: period)
  end

  def currency
    family.currency
  end

  def syncing?
    sync_status_monitor.syncing?
  end

  private
    def sync_status_monitor
      @sync_status_monitor ||= SyncStatusMonitor.new(family)
    end

    def account_totals
      @account_totals ||= AccountTotals.new(family, user: user, sync_status_monitor: sync_status_monitor)
    end

    def net_worth_series_builder
      @net_worth_series_builder ||= NetWorthSeriesBuilder.new(family, user: user)
    end

    def sorted(accounts)
      account_order = user&.account_order
      order_key = account_order&.key || "name_asc"

      case order_key
      when "name_asc"
        sort_by_name(accounts)
      when "name_desc"
        sort_by_name(accounts).reverse
      when "balance_asc"
        sort_by_balance(accounts)
      when "balance_desc"
        sort_by_balance(accounts, descending: true)
      else
        accounts
      end
    end

    # Array#sort_by isn't stable, so accounts with an equal sort value could
    # swap places between renders; the id tie-break keeps the order fixed.
    def sort_by_name(accounts)
      accounts.sort_by { |account| [ account.name.to_s.downcase, account.id ] }
    end

    # Compares balances in the family currency rather than raw amounts.
    # Accounts whose currency has no stored exchange rate cannot be compared,
    # so they go last (by name) in either direction instead of being ranked
    # by an unconverted or 1:1 amount.
    def sort_by_balance(accounts, descending: false)
      comparable, unknown = accounts.partition { |account| balance_comparable?(account) }
      sorted = comparable.sort_by { |account| [ account.converted_balance, account.id ] }
      sorted.reverse! if descending
      sorted + sort_by_name(unknown)
    end

    def balance_comparable?(account)
      account.currency == family.currency || sort_exchange_rates[account.currency].present?
    end

    def sort_exchange_rates
      @sort_exchange_rates ||= begin
        rows = account_totals.asset_accounts + account_totals.liability_accounts
        foreign_currencies = rows.filter_map { |row| row.currency if row.currency != family.currency }
        ExchangeRate.rates_for(foreign_currencies, to: family.currency, date: Date.current, fallback: nil)
      end
    end
end
