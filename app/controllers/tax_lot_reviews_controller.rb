class TaxLotReviewsController < ApplicationController
  def show
    @review = TaxLotReview.new(user: Current.user)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.tax_lot_review"), nil ] ]
  end
end
