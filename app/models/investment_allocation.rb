# How the investment holdings a user can access are distributed, by security,
# sector, country, asset class and so on, plus the holdings whose data is too
# incomplete to trust (no cost basis, no recent price).
#
# Value is each holding's current market value in family currency. A holding in
# a currency with no exchange rate is excluded and reported (never counted 1:1),
# and an attribute the security does not have is an explicit "Unclassified"
# segment rather than a silent gap, so the segments always add up to the total.
class InvestmentAllocation
  GROUPINGS = %w[security asset_class asset_sub_class sector country region account currency kind].freeze
  UNCLASSIFIED = "Unclassified".freeze
  FUND_UNREPORTED = "Fund holdings not reported".freeze
  FUND_MIX_LABELS = { "stock" => "Equity", "bond" => "Fixed Income", "cash" => "Liquidity" }.freeze
  STALE_PRICE_AFTER_DAYS = 5

  Segment = Data.define(:label, :amount, :weight, :count)
  DataQualityIssue = Data.define(:kind, :holding, :security, :detail)

  attr_reader :user, :by

  def initialize(user:, by: "security")
    @user = user
    @by = GROUPINGS.include?(by.to_s) ? by.to_s : "security"
  end

  def family = user.family
  def currency = family.currency

  def segments
    @segments ||= begin
      sums = Hash.new { |hash, key| hash[key] = [ BigDecimal("0"), 0 ] }
      priced.each do |holding, value|
        slices = look_through(holding, value) || [ [ label_for(holding), value ] ]
        slices.each do |label, amount|
          entry = sums[label]
          entry[0] += amount
          entry[1] += 1
        end
      end
      total_value = total
      sums.map { |label, (amount, count)| Segment.new(label: label, amount: amount, weight: total_value.positive? ? amount / total_value * 100 : nil, count: count) }
          .sort_by { |segment| [ segment.label == UNCLASSIFIED ? 1 : 0, -segment.amount ] }
    end
  end

  OTHER = "Other".freeze
  # Buckets that mean "no answer" rather than a category; never folded into Other.
  FIXED_LABELS = [ UNCLASSIFIED, FUND_UNREPORTED ].freeze

  # The segments as drawn: the largest `limit` categories, then the small ones
  # folded into one Other bucket so the bar stays readable. The fixed buckets
  # stay separate and last. Amounts and weights still add up to the total.
  def display_segments(limit: 8)
    real, fixed = segments.partition { |segment| FIXED_LABELS.exclude?(segment.label) }
    return segments if real.size <= limit

    head, tail = real.first(limit), real.drop(limit)
    other = Segment.new(
      label: OTHER,
      amount: tail.sum(BigDecimal("0"), &:amount),
      weight: tail.any? { |segment| segment.weight.nil? } ? nil : tail.sum(BigDecimal("0")) { |segment| segment.weight },
      count: tail.sum(&:count)
    )
    head + [ other ] + fixed.sort_by { |segment| segment.label == UNCLASSIFIED ? 1 : 0 }
  end

  def total
    @total ||= priced.sum(BigDecimal("0")) { |_, value| value }
  end

  def excluded_count
    excluded.size
  end

  def missing_rates
    excluded.map { |holding| holding.currency }.uniq.sort
  end

  def accounts
    @accounts ||= family.accounts.visible.included_in_reports.where(accountable_type: %w[Investment Crypto]).included_in_finances_for(user)
  end

  def data_quality(as_of: Date.current)
    return [] if holdings.empty?

    issues = []
    holdings.each do |holding|
      next if holding.security.cash?

      issues << DataQualityIssue.new(kind: :missing_cost_basis, holding: holding, security: holding.security, detail: nil) if holding.avg_cost.nil?
    end

    securities = holdings.map(&:security).uniq.reject { |security| security.cash? || security.offline? }
    latest = Security::Price.where(security_id: securities.map(&:id)).group(:security_id).maximum(:date)
    securities.each do |security|
      date = latest[security.id]
      issues << DataQualityIssue.new(kind: :stale_price, holding: nil, security: security, detail: date) if date.nil? || date < as_of - STALE_PRICE_AFTER_DAYS
    end

    kinds = %i[missing_cost_basis stale_price]
    issues.sort_by { |issue| [ kinds.index(issue.kind), issue.security.ticker.to_s ] }
  end

  private
    def holdings
      @holdings ||= Holding::CurrentForInvestmentAccounts.new(accounts.select(:id)).relation.includes(:security, :account).to_a
                          .reject { |holding| holding.security.nil? || holding.security.cash? }
    end

    def rates
      @rates ||= begin
        foreign = holdings.map(&:currency).compact.uniq - [ currency ]
        foreign.empty? ? {} : ExchangeRate.rates_for(foreign, to: currency, date: Date.current, fallback: nil).compact
      end
    end

    def priced
      @priced ||= holdings.filter_map do |holding|
        next if holding.amount.nil?

        rate = holding.currency == currency ? 1 : rates[holding.currency]
        next if rate.nil?

        value = holding.amount.to_d * rate
        [ holding, value ] if value.positive?
      end
    end

    def excluded
      @excluded ||= holdings.select { |holding| holding.amount.present? && holding.currency != currency && rates[holding.currency].nil? }
    end

    # A fund's value split by what the provider reports it holds, for the sector
    # and asset-class views only. Returns nil (the fund stays one block under its
    # own label) unless the provider gave weights that are plausible: each between
    # 0 and 1 and summing to no more than 1. A sector list that sums to less than 1
    # leaves the rest as an explicit "not reported" slice rather than spreading it
    # over the names that were listed.
    def look_through(holding, value)
      return nil unless %w[sector asset_class].include?(by)
      return nil unless holding.security.asset_sub_class.in?(%w[etf mutual_fund])

      data = fundamentals[holding.security_id]
      return nil unless data

      weights = by == "sector" ? data["fund_sectors"] : fund_mix_labels(data["fund_mix"])
      return nil unless weights.is_a?(Hash) && weights.any?
      return nil unless weights.values.all? { |weight| weight.is_a?(Numeric) && weight.between?(0, 1) }

      decimals = weights.transform_values { |weight| BigDecimal(weight.to_s) }
      total = decimals.values.sum
      return nil if total > BigDecimal("1.001") || total <= 0

      slices = decimals.select { |_, weight| weight.positive? }.map { |label, weight| [ label, value * weight ] }
      rest = [ BigDecimal("1") - total, BigDecimal("0") ].max
      slices << [ FUND_UNREPORTED, value * rest ] if rest > BigDecimal("0.005")
      slices
    end

    def fund_mix_labels(mix)
      return nil unless mix.is_a?(Hash)

      mix.each_with_object({}) { |(key, weight), out| out[FUND_MIX_LABELS[key]] = weight if FUND_MIX_LABELS[key] }
    end

    def fundamentals
      @fundamentals ||= SecurityFundamental.where(security_id: holdings.map(&:security_id).uniq).index_by(&:security_id).transform_values(&:payload)
    end

    def label_for(holding)
      security = holding.security
      case by
      when "security" then security.ticker
      when "account" then holding.account.name
      when "currency" then holding.currency
      when "country" then security.country_code.presence || UNCLASSIFIED
      when "asset_class", "asset_sub_class", "sector", "region", "kind"
        security.public_send(by).to_s.tr("_", " ").presence&.then { |value| by == "sector" ? value : value.titleize } || UNCLASSIFIED
      end
    end
end
