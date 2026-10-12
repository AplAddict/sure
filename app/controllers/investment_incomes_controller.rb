class InvestmentIncomesController < ApplicationController
  include Periodable

  def show
    @review = InvestmentIncomeReview.new(user: Current.user, period: @period)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ "Income & Performance", nil ] ]
  end
end
