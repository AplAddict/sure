class TaxLotReviewsController < ApplicationController
  TABS = %w[lots harvest].freeze

  def show
    @tab = params[:tab].presence_in(TABS) || "lots"
    @review = review if @tab == "lots" || request.format.csv?
    @harvest = TaxLossHarvest.new(user: Current.user) if @tab == "harvest"
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.tax_lot_review"), nil ] ]

    respond_to do |format|
      format.html
      format.csv do
        send_data @review.to_csv, type: "text/csv", disposition: %(attachment; filename="tax-lots-#{Date.current.iso8601}.csv")
      end
    end
  end

  private
    def review
      TaxLotReview.new(user: Current.user, ticker: params[:ticker], term: params[:term], sort: params[:sort], direction: params[:dir])
    end
end
