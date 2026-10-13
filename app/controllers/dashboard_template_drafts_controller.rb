class DashboardTemplateDraftsController < ApplicationController
  rescue_from DashboardPageConfigurable::DashboardPagesValidationError, with: :render_validation_error

  def create
    raw = params.fetch(:draft, nil)
    validator = Dashboard::TemplateDraft.new(user: Current.user)
    draft = if params.key?(:selections)
      validator.resolve_intent!(raw, selections: params[:selections])
    else
      validator.validate!(raw)
    end
    render json: { draft: draft }
  end

  private
    def render_validation_error(error)
      render json: { error: "validation_failed", message: error.message }, status: :unprocessable_entity
    end
end
