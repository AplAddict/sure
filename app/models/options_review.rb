# Read-only list of the option contracts in the accounts a user can access.
# Options never enter equity holdings, cost basis, performance or net worth;
# this only presents the broker's contract snapshot.
class OptionsReview
  Row = Data.define(:account, :position, :freshness, :synced_at) do
    def expired?(today = Date.current) = position.days_to_expiry(today)&.negative? || false
    def expiring_soon?(today = Date.current) = !expired?(today) && (days = position.days_to_expiry(today)) ? days <= EXPIRING_SOON_DAYS : false
  end

  # Underlying group: its contracts and a gain subtotal that exists only when
  # every contract in it has a measurable gain (never a partial sum).
  Group = Data.define(:underlying, :rows, :currency) do
    def gain
      gains = rows.map { |row| row.position.gain }
      gains.any?(&:nil?) ? nil : gains.sum(BigDecimal("0"))
    end

    def cost_total
      costs = rows.map { |row| row.position.cost_total }
      costs.any?(&:nil?) ? nil : costs.sum(BigDecimal("0"))
    end

    def unmeasured_count = rows.count { |row| row.position.gain.nil? }
  end

  SORTS = %w[expiry underlying contract gain account].freeze
  EXPIRING_SOON_DAYS = 7

  attr_reader :user, :sort, :direction

  def initialize(user:, sort: nil, direction: nil)
    @user = user
    @sort = SORTS.include?(sort.to_s) ? sort.to_s : "expiry"
    @direction = direction.to_s == "desc" ? "desc" : "asc"
  end

  # Every contract, in the chosen order. Contracts with nothing to sort on
  # (no expiry, no measurable gain) always sit last, whichever way it is sorted.
  def rows
    @rows ||= begin
      present, missing = unsorted_rows.partition { |row| !sort_key(row).nil? }
      ordered = present.sort_by { |row| [ sort_key(row), row.position.contract ] }
      ordered.reverse! if direction == "desc"
      ordered + missing.sort_by { |row| row.position.contract }
    end
  end

  # Contracts grouped by underlying. Groups follow the order of their first
  # contract so the chosen sort still reads top to bottom.
  def groups
    @groups ||= rows.group_by { |row| row.position.underlying || "—" }
                    .map { |underlying, grouped| Group.new(underlying: underlying, rows: grouped, currency: grouped.first.position.currency) }
  end

  def expiring_soon_count = rows.count(&:expiring_soon?)
  def expired_count = rows.count(&:expired?)

  # Net unrealized gain across all contracts, or nil when any contract's gain is
  # unmeasured or the contracts are in more than one currency.
  def total_gain
    return nil if rows.empty? || rows.map { |row| row.position.currency }.uniq.size > 1

    gains = rows.map { |row| row.position.gain }
    gains.any?(&:nil?) ? nil : gains.sum(BigDecimal("0"))
  end

  def currency = rows.first&.position&.currency

  private
    def unsorted_rows
      account_ids = user.accessible_accounts.visible.pluck(:id)

      SnaptradeAccount.linked_to(account_ids).flat_map do |provider_account|
        account = provider_account.current_account
        provider_account.option_positions_snapshot.map do |position|
          Row.new(account: account, position: position, freshness: provider_account.snapshot_freshness, synced_at: provider_account.last_holdings_sync)
        end
      end
    end

    def sort_key(row)
      case sort
      when "expiry" then row.position.expiration
      when "underlying" then row.position.underlying&.downcase
      when "contract" then row.position.contract.downcase
      when "gain" then row.position.gain
      when "account" then row.account.name.downcase
      end
    end
end
