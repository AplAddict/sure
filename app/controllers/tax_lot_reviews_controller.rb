class TaxLotReviewsController < ApplicationController
  TABS = %w[lots harvest].freeze

  def show
    @tab = params[:tab].presence_in(TABS) || "lots"
    @review = TaxLotReview.new(user: Current.user) if @tab == "lots"
    @harvest = TaxLossHarvest.new(user: Current.user) if @tab == "harvest"
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.tax_lot_review"), nil ] ]
  end
end
