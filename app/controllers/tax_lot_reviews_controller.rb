class TaxLotReviewsController < ApplicationController
  def show
    @review = TaxLotReview.new(user: Current.user)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ "Tax-Aware Lot Review", nil ] ]
  end
end
