class DashboardPagesController < ApplicationController
  rescue_from DashboardPageConfigurable::DashboardPagesValidationError, with: :render_validation_error

  def index
    registry = Dashboard::WidgetRegistry.all
    registry = registry.reject(&:investment_required) unless Current.user.investment_dashboard_access?
    render json: {
      pages: Current.user.dashboard_pages,
      current_page: Current.user.dashboard_current_page,
      widget_registry: registry.map(&:as_json)
    }
  end

  def create
    permitted = page_params
    page = Current.user.create_dashboard_page!(permitted[:name], page_id: permitted[:id])
    render json: { page: page }, status: :created
  end

  def update
    page = Current.user.rename_dashboard_page!(params[:id], page_params.fetch(:name, nil))
    render json: { page: page }
  end

  def destroy
    Current.user.delete_dashboard_page!(params[:id])
    head :no_content
  end

  def current
    Current.user.select_dashboard_page!(params[:page_id])
    render json: { current_page: Current.user.dashboard_current_page }
  end

  def order
    pages = Current.user.reorder_dashboard_pages!(params[:page_ids])
    render json: { pages: pages }
  end

  private
    def page_params
      params.fetch(:page, ActionController::Parameters.new).permit(:id, :name)
    end

    def render_validation_error(error)
      render json: { error: "validation_failed", message: error.message }, status: :unprocessable_entity
    end
end
