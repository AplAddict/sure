class OptionsReviewsController < ApplicationController
  def show
    @review = OptionsReview.new(user: Current.user)
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.options_review"), nil ] ]
  end
end
