class Holding::CurrentForInvestmentAccounts
  def initialize(account_ids)
    @account_ids = account_ids
  end

  # Non-zero current holdings: a linked account's latest import, else each security's latest row.
  def relation
    return Holding.none if account_ids.empty?

    Holding
      .where(account_id: account_ids)
      .where.not(qty: 0)
      .and(Holding.where(id: provider_snapshot_ids).or(Holding.where(id: latest_manual_ids)))
  end

  private
    attr_reader :account_ids

    def provider_holdings
      Holding.where(account_id: account_ids).where.not(account_provider_id: nil)
    end

    # Match on the import day, not the holding date: one import may retain each
    # security's own price date.
    def provider_snapshot_ids
      import_days = provider_holdings
        .group(:account_id)
        .select("holdings.account_id, MAX(holdings.updated_at::date) AS import_day")

      provider_holdings
        .joins(<<~SQL.squish)
          INNER JOIN (#{import_days.to_sql}) import_days
            ON import_days.account_id = holdings.account_id
           AND import_days.import_day = holdings.updated_at::date
        SQL
        .select(:id)
    end

    # Manual accounts use the latest row for each security in account currency.
    def latest_manual_ids
      Holding
        .joins(:account)
        .where(account_id: account_ids)
        .where(accounts: { id: account_ids })
        .where.not(account_id: provider_holdings.select(:account_id))
        .where("holdings.currency = accounts.currency")
        .select("DISTINCT ON (holdings.account_id, holdings.security_id) holdings.id")
        .order(Arel.sql("holdings.account_id, holdings.security_id, holdings.date DESC"))
    end
end
