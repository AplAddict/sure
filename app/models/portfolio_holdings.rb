# Every position the member can see, grouped by account, with the tax lots the
# broker reported where it reported them. Read-only and scoped to
# user.accessible_accounts, so it can never show another member's positions.
#
# Anything Sure cannot measure is nil and rendered as unavailable, never zero.
# Lots are shown only when the broker's own lots add up to the position; a set
# that does not is dropped rather than patched, because a guessed acquisition
# date or basis would be a fabricated tax fact.
class PortfolioHoldings
  SORTS = %w[symbol quantity price avg_cost cost_basis market_value gain gain_pct weight].freeze
  QTY_TOLERANCE = BigDecimal("0.0001")

  Lot = Data.define(:acquired_on, :quantity, :cost_basis, :market_value) do
    def gain = cost_basis && market_value ? market_value - cost_basis : nil
    def gain_pct = cost_basis&.positive? && gain ? gain / cost_basis * 100 : nil
    def unit_cost = cost_basis && quantity.positive? ? cost_basis / quantity : nil
  end

  Position = Data.define(:account, :security, :quantity, :price, :avg_cost, :cost_basis, :market_value, :currency, :weight, :lots, :day_change) do
    def ticker = security.ticker
    def name = security.name.presence || security.ticker
    def gain = cost_basis && market_value ? market_value - cost_basis : nil
    def gain_pct = cost_basis&.positive? && gain ? gain / cost_basis * 100 : nil
    def day_gain = day_change&.value
    def day_gain_pct = day_change&.percent
    def lots? = lots.any?
  end

  AccountBlock = Data.define(:account, :positions, :market_value, :cost_basis, :cash, :currency) do
    def gain = cost_basis && market_value ? market_value - cost_basis : nil
    def complete_basis? = positions.all?(&:cost_basis)
    def lot_count = positions.sum { |position| position.lots.size }
  end

  attr_reader :user, :sort, :direction

  def initialize(user:, account_id: nil, sort: nil, direction: nil)
    @user = user
    @account_id = account_id.presence
    @sort = SORTS.include?(sort.to_s) ? sort.to_s : "market_value"
    @direction = direction.to_s == "asc" ? "asc" : (direction.to_s == "desc" ? "desc" : default_direction)
  end

  # Accounts offered in the scope picker (all of them, regardless of the filter).
  def accounts
    @accounts ||= user.accessible_accounts.visible.where(accountable_type: %w[Investment Crypto]).includes(:accountable).order(:name).to_a
  end

  def selected_account
    accounts.find { |account| account.id == @account_id }
  end

  # False when a requested account is not one the member can see.
  def scope_valid?
    @account_id.nil? || selected_account.present?
  end

  def blocks
    @blocks ||= begin
      scoped = selected_account ? [ selected_account ] : accounts
      scoped = [] unless scope_valid?
      lots_by_account = provider_lots(scoped)
      holdings = Holding::CurrentForInvestmentAccounts.new(scoped.map(&:id)).relation.includes(:security).to_a.reject { |holding| holding.qty.to_d.zero? }.group_by(&:account_id)

      scoped.filter_map do |account|
        rows = holdings.fetch(account.id, [])
        next if rows.empty? && account.cash_balance.to_d.zero?

        build_block(account, rows, lots_by_account.fetch(account.id, {}))
      end
    end
  end

  # Market value per account, for the cross-account chart. Mixed currencies are
  # not netted into a single number: each block keeps its own currency.
  def chart_rows(block)
    block.positions.sort_by { |position| -(position.market_value || 0) }.first(12).map do |position|
      { ticker: position.ticker, weight: position.weight, gain_pct: position.gain_pct, market_value: position.market_value }
    end
  end

  SidebarPosition = Data.define(:ticker, :name, :logo_url, :price, :market_value, :currency, :weight, :day_gain, :day_gain_pct, :gain, :gain_pct)
  SidebarAccount = Data.define(:account, :positions, :market_value)

  # Sidebar values are sourced from the current holding record. Cost-basis or
  # prior-day data that cannot be evidenced stays nil and is rendered as —.
  # Lots remain on the full holdings page because they are broker tax records.
  def sidebar_accounts
    @sidebar_accounts ||= begin
      current_rows = Holding::CurrentForInvestmentAccounts.new(accounts.map(&:id)).relation.includes(:security).to_a
        .reject { |holding| holding.qty.to_d.zero? || holding.security.nil? }
      holdings = current_rows.group_by(&:account_id)
      previous_rows = sidebar_previous_holdings(current_rows)

      accounts.filter_map do |account|
        rows = holdings[account.id]
        next if rows.blank?

        total = rows.sum(BigDecimal("0")) { |holding| holding.amount.to_d }
        positions = rows.sort_by { |holding| -holding.amount.to_d }.map do |holding|
          prior = previous_rows[sidebar_position_key(holding)]&.reverse_each&.find { |candidate| candidate.date < holding.date }
          day_change = prior&.amount_money ? Trend.new(current: holding.amount_money, previous: prior.amount_money) : nil
          basis_per_share = holding.cost_basis
          known_basis = basis_per_share && (holding.cost_basis_locked? || basis_per_share.positive?)
          cost_basis = known_basis ? holding.qty.to_d * basis_per_share.to_d : nil
          gain = cost_basis ? holding.amount.to_d - cost_basis : nil

          SidebarPosition.new(
            ticker: holding.security.ticker,
            name: holding.security.name.presence || holding.security.ticker,
            logo_url: holding.security.display_logo_url,
            price: holding.price&.to_d,
            market_value: holding.amount.to_d,
            currency: holding.currency,
            weight: total.positive? ? holding.amount.to_d / total * 100 : nil,
            day_gain: day_change&.value,
            day_gain_pct: day_change&.percent,
            gain: gain,
            gain_pct: cost_basis&.positive? && gain ? gain / cost_basis * 100 : nil
          )
        end
        SidebarAccount.new(account: account, positions: positions, market_value: total)
      end
    end
  end

  def lots_available?
    blocks.any? { |block| block.lot_count.positive? }
  end

  private
    # Fetch prior snapshots for every displayed holding in one query. Rendering
    # the sidebar on unrelated pages must not issue one query per position.
    def sidebar_previous_holdings(current_rows)
      return {} if current_rows.empty?

      account_ids = current_rows.map(&:account_id).uniq
      security_ids = current_rows.map(&:security_id).uniq
      current_ids = current_rows.map(&:id)
      Holding.where(account_id: account_ids, security_id: security_ids).where.not(id: current_ids)
        .select(:id, :account_id, :security_id, :currency, :date, :amount)
        .order(:date).to_a.group_by { |holding| sidebar_position_key(holding) }
    end

    def sidebar_position_key(holding)
      [ holding.account_id, holding.security_id, holding.currency ]
    end

    def default_direction = %w[symbol].include?(@sort) ? "asc" : "desc"

    def build_block(account, rows, lots_by_security)
      total = rows.sum(BigDecimal("0")) { |holding| holding.amount.to_d }
      positions = rows.filter_map { |holding| build_position(account, holding, total, lots_by_security) }
      positions = sort_positions(positions)

      known_basis = positions.all?(&:cost_basis) && positions.any?
      AccountBlock.new(
        account: account,
        positions: positions,
        market_value: positions.sum(BigDecimal("0")) { |position| position.market_value.to_d },
        cost_basis: known_basis ? positions.sum(BigDecimal("0")) { |position| position.cost_basis } : nil,
        cash: account.cash_balance,
        currency: account.currency
      )
    end

    def build_position(account, holding, account_total, lots_by_security)
      return nil unless holding.security

      quantity = holding.qty.to_d
      avg_cost = holding.avg_cost&.amount
      cost_basis = avg_cost && quantity.positive? ? avg_cost * quantity : nil
      value = holding.amount.to_d

      Position.new(
        account: account,
        security: holding.security,
        quantity: quantity,
        price: holding.price&.to_d,
        avg_cost: avg_cost,
        cost_basis: cost_basis,
        market_value: value,
        currency: holding.currency,
        weight: account_total.positive? ? value / account_total * 100 : nil,
        lots: verified_lots(lots_by_security[holding.security.ticker.to_s.upcase], quantity),
        day_change: holding.day_change
      )
    end

    def sort_positions(positions)
      keyed = positions.map { |position| [ sort_value(position), position ] }
      present, missing = keyed.partition { |value, _| !value.nil? }
      ordered = present.sort_by { |value, position| [ value, position.ticker ] }.map(&:last)
      ordered.reverse! if direction == "desc"
      # Unmeasurable rows always sit last, whichever way the column is sorted
      ordered + missing.map(&:last).sort_by(&:ticker)
    end

    def sort_value(position)
      case sort
      when "symbol" then position.ticker.to_s.downcase
      when "quantity" then position.quantity
      when "price" then position.price
      when "avg_cost" then position.avg_cost
      when "cost_basis" then position.cost_basis
      when "market_value" then position.market_value
      when "gain" then position.gain
      when "gain_pct" then position.gain_pct
      when "weight" then position.weight
      end
    end

    # { account_id => { "TICKER" => [raw lot hashes] } } from the broker payload of
    # each account (only SnapTrade supplies lots today).
    def provider_lots(scoped_accounts)
      by_account = {}
      account_ids = scoped_accounts.map(&:id)
      return by_account if account_ids.empty?

      SnaptradeAccount.joins(:account_provider).where(account_providers: { account_id: account_ids }).includes(:account_provider).each do |provider_account|
        account_id = provider_account.account_provider&.account_id
        next unless account_ids.include?(account_id)

        payload = provider_account.raw_holdings_payload
        positions = payload.is_a?(Hash) ? Array(payload["positions"] || payload[:positions]) : Array(payload)
        positions.each do |raw|
          position = raw.to_h.with_indifferent_access
          symbol = position.dig(:instrument, :symbol)
          symbol = symbol[:symbol] if symbol.is_a?(Hash)
          next if symbol.blank?

          (by_account[account_id] ||= {})[symbol.to_s.upcase] = Array(position[:tax_lots]).map { |lot| lot.to_h.with_indifferent_access }
        end
      end
      by_account
    end

    # The broker's lots, oldest first, only if their quantities add up to the
    # position Sure holds. Lot cost_basis from SnapTrade is a whole-lot total.
    def verified_lots(raw_lots, position_quantity)
      return [] if raw_lots.blank?

      lots = raw_lots.filter_map do |lot|
        quantity = decimal(lot[:quantity])
        next unless quantity&.positive?

        Lot.new(acquired_on: parse_date(lot[:original_purchase_date]), quantity: quantity, cost_basis: decimal(lot[:cost_basis]), market_value: decimal(lot[:current_value]))
      end
      return [] if lots.empty?

      held = lots.sum(BigDecimal("0")) { |lot| lot.quantity }
      return [] if (held - position_quantity).abs > [ position_quantity.abs * BigDecimal("0.001"), QTY_TOLERANCE ].max

      lots.sort_by { |lot| lot.acquired_on || Date.new(9999, 1, 1) }
    end

    def decimal(value)
      value.present? ? BigDecimal(value.to_s) : nil
    rescue ArgumentError
      nil
    end

    def parse_date(value)
      value.present? ? Time.zone.parse(value.to_s)&.to_date : nil
    rescue ArgumentError
      nil
    end
end
