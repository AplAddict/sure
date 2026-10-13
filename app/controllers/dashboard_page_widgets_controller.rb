class DashboardPageWidgetsController < ApplicationController
  rescue_from DashboardPageConfigurable::DashboardPagesValidationError, with: :render_validation_error

  def create
    widget = Current.user.add_dashboard_widget!(params[:page_id], widget_params.fetch(:key, nil))
    render json: { widget: widget }, status: :created
  end

  def update
    permitted = widget_params
    widget = Current.user.update_dashboard_widget!(
      params[:page_id],
      params[:widget_key],
      collapsed: permitted.key?(:collapsed) ? permitted[:collapsed] : nil,
      layout: permitted.key?(:layout) ? permitted[:layout] : nil
    )
    render json: { widget: widget }
  end

  def destroy
    Current.user.remove_dashboard_widget!(params[:page_id], params[:widget_key])
    head :no_content
  end

  def order
    page = Current.user.reorder_dashboard_widgets!(params[:page_id], params[:widget_keys])
    render json: { page: page }
  end

  private
    def widget_params
      raw = params.fetch(:widget, ActionController::Parameters.new)
      unless raw.respond_to?(:permit)
        raise DashboardPageConfigurable::DashboardPagesValidationError, "widget must be an object"
      end

      permitted = raw.permit(:key, :collapsed).to_h
      if raw.key?(:layout)
        layout = raw[:layout]
        permitted[:layout] = layout.respond_to?(:to_unsafe_h) ? layout.to_unsafe_h : layout
      end
      permitted
    end

    def render_validation_error(error)
      render json: { error: "validation_failed", message: error.message }, status: :unprocessable_entity
    end
end
