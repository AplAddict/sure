# Flags unrealized losses in one member's taxable accounts that clear the
# harvest threshold. Built from TaxLossHarvest, so it inherits that model's
# honesty rules: positions with unknown cost basis or no exchange rate are
# never counted, and the scope is the member's own accessible accounts.
#
# Priority rises in Q4 because a loss only counts for the tax year it is
# realized in; the rest of the year it is a quiet heads-up.
class Insight::Generators::TaxLossHarvestGenerator < Insight::Generator
  produces "tax_loss_harvest"

  YEAR_END_PRIORITY_FROM_MONTH = 11

  def generate
    harvest = TaxLossHarvest.new(user: user)
    candidates = harvest.candidates
    return [] if candidates.empty?

    loss = candidates.sum(BigDecimal("0")) { |row| row.loss.amount.abs }
    largest = candidates.min_by { |row| row.loss.amount }
    flagged = candidates.count { |row| row.wash_flags.any? }

    [
      build_insight(
        insight_type: "tax_loss_harvest",
        priority: Date.current.month >= YEAR_END_PRIORITY_FROM_MONTH ? "high" : "medium",
        title: I18n.t("insights.titles.tax_loss_harvest", count: candidates.size),
        template_key: flagged.positive? ? "tax_loss_harvest.flagged" : "tax_loss_harvest.clear",
        facts: {
          count: candidates.size,
          loss: format_money(loss),
          largest: largest.ticker,
          largest_loss: format_money(largest.loss.amount.abs),
          flagged: flagged
        },
        metadata: {
          candidate_count: candidates.size,
          loss_bucket: bucket(loss),
          flagged: flagged,
          largest: largest.ticker
        },
        dedup_key: user_key("tax_loss_harvest", month_token)
      )
    ]
  end

  private
    # ~10% steps so a day's price drift does not rewrite and resurface the card.
    def bucket(amount)
      value = amount.to_f
      return 0 if value <= 0

      step = 10**(Math.log10(value).floor - 1)
      (value / step).round * step
    end
end
