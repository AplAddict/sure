class BalanceSheet::HistoricalAccountScope
  def initialize(family, user: nil)
    @family = family
    @user = user
  end

  def account_ids
    relation.pluck(:id)
  end

  def relation
    scope = family.accounts.historical.included_in_reports
                  .joins("LEFT JOIN physical_metals ON physical_metals.id = accounts.accountable_id AND accounts.accountable_type = 'PhysicalMetal'")
                  .where("accounts.accountable_type != ? OR physical_metals.valuation_state = ?", "PhysicalMetal", "manually_valued")
    user.present? ? scope.included_in_finances_for(user) : scope
  end

  private
    attr_reader :family, :user
end
