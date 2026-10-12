class InvestmentIncomesController < ApplicationController
  include Periodable

  def show
    @review = InvestmentIncomeReview.new(user: Current.user, period: @period)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.investment_income"), nil ] ]
  end
end
