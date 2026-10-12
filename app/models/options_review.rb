# Read-only list of the option contracts in the accounts a user can access.
# Options never enter equity holdings, cost basis, performance or net worth;
# this only presents the broker's contract snapshot.
class OptionsReview
  Row = Data.define(:account, :position, :freshness, :synced_at)

  attr_reader :user

  def initialize(user:)
    @user = user
  end

  def rows
    @rows ||= begin
      account_ids = user.accessible_accounts.visible.pluck(:id)

      SnaptradeAccount.linked_to(account_ids).flat_map do |provider_account|
        account = provider_account.current_account
        provider_account.option_positions_snapshot.map do |position|
          Row.new(account: account, position: position, freshness: provider_account.snapshot_freshness, synced_at: provider_account.last_holdings_sync)
        end
      end.sort_by { |row| [ row.position.expiration || Date.new(9999, 12, 31), row.position.contract ] }
    end
  end
end
