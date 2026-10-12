# Fills a security's asset class, sub-class, sector and industry from what the
# market-data provider reports about it. Nothing is inferred: a field the
# provider did not send is left as it was, and an unrecognised quote type changes
# nothing. A value set by the user or the AI, or locked, is never replaced.
class Security::Classifier
  SUB_CLASS_BY_QUOTE_TYPE = { "EQUITY" => "stock", "ETF" => "etf", "MUTUALFUND" => "mutual_fund" }.freeze

  # A fund is classed by what it mostly holds. Anything mixed stays unclassed
  # rather than being forced into one bucket.
  PREDOMINANT = BigDecimal("0.95")

  def self.apply(security, data) = new(security, data).apply

  def initialize(security, data)
    @security = security
    @data = data.is_a?(Hash) ? data : {}
  end

  def apply
    return false if blocked?

    sub_class = SUB_CLASS_BY_QUOTE_TYPE[@data["quote_type"]]
    return false unless sub_class

    attrs = { asset_sub_class: sub_class, classification_source: "provider" }
    attrs[:asset_class] = asset_class_for(sub_class) if asset_class_for(sub_class)
    attrs[:sector] = @data["sector"] if @data["sector"].present?
    attrs[:industry] = @data["industry"] if @data["industry"].present?

    @security.update!(attrs)
    true
  end

  private
    def blocked?
      @security.classification_locked? || %w[manual ai].include?(@security.classification_source)
    end

    def asset_class_for(sub_class)
      return "equity" if sub_class == "stock"

      mix = @data["fund_mix"]
      return nil unless mix.is_a?(Hash)

      stock = BigDecimal(mix["stock"].to_s)
      bond = BigDecimal(mix["bond"].to_s)
      return "equity" if stock >= PREDOMINANT
      return "fixed_income" if bond >= PREDOMINANT

      nil
    end
end
