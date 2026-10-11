# Notes when one security is a large share of a member's investment portfolio.
# Uses InvestmentStatement scoped to that member (their owned and shared
# accounts that count in their finances), so the percentages never include
# anyone else's holdings. Descriptive only: a broad index fund can
# legitimately be most of a portfolio.
class Insight::Generators::PositionConcentrationGenerator < Insight::Generator
  produces "position_concentration"

  NOTABLE_WEIGHT = 25
  HIGH_WEIGHT = 40
  MAX_INSIGHTS = 2

  def generate
    statement = InvestmentStatement.new(family, user: user)

    statement.allocation
      .select { |holding| holding.weight >= NOTABLE_WEIGHT }
      .first(MAX_INSIGHTS)
      .map do |holding|
        weight = holding.weight.to_f.round(0).to_i

        build_insight(
          insight_type: "position_concentration",
          priority: holding.weight >= HIGH_WEIGHT ? "medium" : "low",
          title: I18n.t("insights.titles.position_concentration", ticker: holding.ticker),
          template_key: "position_concentration",
          facts: {
            ticker: holding.ticker,
            name: holding.name,
            weight: weight,
            value: holding.amount.format
          },
          metadata: {
            ticker: holding.ticker,
            weight_bucket: (weight / 5) * 5
          },
          dedup_key: user_key("position_concentration", holding.ticker, month_token)
        )
      end
  end
end
