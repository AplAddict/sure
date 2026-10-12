class OptionsReviewsController < ApplicationController
  def show
    @review = OptionsReview.new(user: Current.user, sort: params[:sort], direction: params[:dir])
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.options_review"), nil ] ]
  end
end
