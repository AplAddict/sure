class InvestmentIncomesController < ApplicationController
  include Periodable

  def show
    @review = InvestmentIncomeReview.new(user: Current.user, period: @period)
    @realized = RealizedGainsReview.new(user: Current.user, period: @period)
    @sections = InvestmentSections.new(namespace: "income", user: Current.user, definitions: section_definitions)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.investment_income"), nil ] ]
  end

  private
    def period_from_key(key)
      return super unless key == "all_time"

      Period.all_time_for(user: Current.user, accountable_types: %w[Investment Crypto])
    end

    def section_definitions
      premium = @review.option_premium
      closing = premium[:sold_to_close] && premium[:bought_to_close] ? premium[:sold_to_close] - premium[:bought_to_close] : nil
      scope = "investment_incomes.show"
      [
        { key: "income", title: t("#{scope}.income"), partial: "investment_incomes/income", locals: { review: @review, premium: premium, closing: closing, currency: @review.currency } },
        { key: "monthly_income", title: t("#{scope}.monthly_income"), partial: "investment_incomes/monthly_income", locals: { review: @review, currency: @review.currency } },
        { key: "cash_flows", title: t("#{scope}.cash_flows"), partial: "investment_incomes/cash_flows", locals: { review: @review, currency: @review.currency } },
        { key: "performance", title: t("#{scope}.performance"), partial: "investment_incomes/performance", locals: { review: @review, currency: @review.currency } },
        { key: "realized_gains", title: t("#{scope}.realized_gains"), partial: "investment_incomes/realized_gains", locals: { realized: @realized, currency: @review.currency } }
      ]
    end
end
