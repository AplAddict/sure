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

  Position = Data.define(:account, :security, :quantity, :price, :avg_cost, :cost_basis, :market_value, :currency, :weight, :lots) do
    def ticker = security.ticker
    def name = security.name.presence || security.ticker
    def gain = cost_basis && market_value ? market_value - cost_basis : nil
    def gain_pct = cost_basis&.positive? && gain ? gain / cost_basis * 100 : nil
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

  SidebarPosition = Data.define(:ticker, :name, :market_value, :currency, :weight)
  SidebarAccount = Data.define(:account, :positions, :market_value)

  # Just ticker, value and weight per account, for the sidebar. It deliberately
  # skips cost basis and lots (both query per position) because it renders on
  # every page; the full page is one click away.
  def sidebar_accounts
    @sidebar_accounts ||= begin
      holdings = Holding::CurrentForInvestmentAccounts.new(accounts.map(&:id)).relation.includes(:security).to_a
        .reject { |holding| holding.qty.to_d.zero? || holding.security.nil? }.group_by(&:account_id)

      accounts.filter_map do |account|
        rows = holdings[account.id]
        next if rows.blank?

        total = rows.sum(BigDecimal("0")) { |holding| holding.amount.to_d }
        positions = rows.sort_by { |holding| -holding.amount.to_d }.map do |holding|
          SidebarPosition.new(
            ticker: holding.security.ticker,
            name: holding.security.name.presence || holding.security.ticker,
            market_value: holding.amount.to_d,
            currency: holding.currency,
            weight: total.positive? ? holding.amount.to_d / total * 100 : nil
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
        lots: verified_lots(lots_by_security[holding.security.ticker.to_s.upcase], quantity)
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
