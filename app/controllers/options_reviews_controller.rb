class OptionsReviewsController < ApplicationController
  def show
    @now = Time.current
    @desk = OptionsDesk.new(user: Current.user, account_id: desk_account_id, now: @now).result
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.options_review"), nil ] ]
  end

  def legacy
    @review = OptionsReview.new(user: Current.user, sort: params[:sort], direction: params[:dir])
    @breadcrumbs = [ [ t("breadcrumbs.home"), root_path ], [ t("breadcrumbs.options_review"), nil ] ]
  end

  private
    # Only a scalar id is forwarded. A present but malformed ?account must fail
    # closed rather than being treated as "all accounts".
    def desk_account_id
      value = params[:account]
      return if value.nil?
      return value if value.is_a?(String) || value.is_a?(Numeric)

      "invalid"
    end
end
