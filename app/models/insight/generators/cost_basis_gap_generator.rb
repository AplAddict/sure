# Positions in a member's taxable accounts with no recorded cost basis. They
# are excluded from every gain/loss figure (never counted as zero), so saying
# so keeps the numbers elsewhere honest. Low priority: it is housekeeping.
class Insight::Generators::CostBasisGapGenerator < Insight::Generator
  produces "cost_basis_gap"

  MAX_LISTED = 3

  def generate
    gaps = TaxLossHarvest.new(user: user).unavailable.select { |item| item.reason == :cost_basis_unknown }
    return [] if gaps.empty?

    tickers = gaps.map(&:ticker).uniq.sort

    [
      build_insight(
        insight_type: "cost_basis_gap",
        priority: "low",
        title: I18n.t("insights.titles.cost_basis_gap", count: tickers.size),
        template_key: "cost_basis_gap",
        facts: {
          count: tickers.size,
          tickers: tickers.first(MAX_LISTED).to_sentence,
          more: [ tickers.size - MAX_LISTED, 0 ].max
        },
        metadata: { count: tickers.size },
        dedup_key: user_key("cost_basis_gap", month_token)
      )
    ]
  end
end
