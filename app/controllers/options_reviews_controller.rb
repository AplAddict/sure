class OptionsReviewsController < ApplicationController
  OptionRow = Data.define(:account, :position, :freshness, :synced_at) do
    def dte
      position.expiration ? (position.expiration - Date.current).to_i : nil
    end
  end

  def show
    account_ids = Current.user.accessible_accounts.visible.pluck(:id).to_set
    @rows = SnaptradeAccount.includes(:account_provider).filter_map do |provider_account|
      account = provider_account.current_account
      next unless account && account_ids.include?(account.id)

      freshness = provider_account.last_holdings_sync.nil? ? "unavailable" : provider_account.last_holdings_sync < 30.hours.ago ? "stale" : "current"
      provider_account.option_positions_snapshot.map { |position| OptionRow.new(account, position, freshness, provider_account.last_holdings_sync) }
    end.flatten.sort_by { |row| [ row.position.expiration || Date.new(9999, 12, 31), row.position.contract ] }
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ "Options Review", nil ] ]
  end
end
