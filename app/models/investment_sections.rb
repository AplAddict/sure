# The ordered, collapsible sections of an Investments page.
#
# Pure ordering/validation: the page supplies the section hashes (key, title,
# partial, locals, visible); this applies the member's saved order and collapsed
# state. A section the member has never placed (added since they last dragged)
# is appended in declaration order, so a new section always appears. Only the
# page's own keys are ever accepted back, so a payload cannot store arbitrary
# strings in the member's preferences.
class InvestmentSections
  attr_reader :namespace, :user, :definitions

  def initialize(namespace:, user:, definitions:)
    @namespace = namespace.to_s
    @user = user
    @definitions = definitions
  end

  def keys
    definitions.map { |section| section[:key] }
  end

  def ordered
    saved = user.investment_section_order(namespace).uniq.filter_map { |key| definitions.find { |section| section[:key] == key } }
    placed = saved.map { |section| section[:key] }
    (saved + definitions.reject { |section| placed.include?(section[:key]) }).select { |section| section[:visible] != false }
  end

  def collapsed?(key)
    user.investment_section_collapsed?(namespace, key)
  end

  def preference_key
    "investments_#{namespace}"
  end

  # Registry used by the preferences endpoint to know each page's valid keys
  # without rendering it.
  def self.valid_keys(namespace)
    KEYS.fetch(namespace.to_s) { raise ArgumentError, "unknown investment section namespace" }
  end

  KEYS = {
    "income" => %w[income monthly_income cash_flows performance realized_gains],
    "holdings" => %w[allocation data_quality accounts],
    "decision" => %w[pulse source_health actions monitor],
    "options" => %w[summary contracts ideas],
    "tax_lots" => %w[totals soon lots],
    "tax_harvest" => %w[summary candidates unavailable],
    "watchlist" => %w[add saved]
  }.freeze
end
