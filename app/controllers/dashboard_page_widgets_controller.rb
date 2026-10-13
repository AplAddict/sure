class DashboardPageWidgetsController < ApplicationController
  rescue_from DashboardPageConfigurable::DashboardPagesValidationError, with: :render_validation_error

  def create
    permitted = widget_params
    widget = Current.user.add_dashboard_widget!(
      params[:page_id],
      permitted.fetch(:key, nil),
      settings: permitted.key?(:settings) ? permitted[:settings] : nil,
      allow_duplicate: permitted.fetch(:allow_duplicate, false)
    )
    render json: { widget: widget }, status: :created
  end

  def update
    permitted = widget_params
    widget = Current.user.update_dashboard_widget!(
      params[:page_id],
      params[:instance_id],
      collapsed: permitted.key?(:collapsed) ? permitted[:collapsed] : nil,
      layout: permitted.key?(:layout) ? permitted[:layout] : nil,
      settings: permitted.key?(:settings) ? permitted[:settings] : nil
    )
    render json: { widget: widget }
  end

  def destroy
    Current.user.remove_dashboard_widget!(params[:page_id], params[:instance_id])
    head :no_content
  end

  def order
    page = Current.user.reorder_dashboard_widgets!(params[:page_id], params[:instance_ids])
    render json: { page: page }
  end

  private
    def widget_params
      raw = params.fetch(:widget, ActionController::Parameters.new)
      unless raw.respond_to?(:permit)
        raise DashboardPageConfigurable::DashboardPagesValidationError, "widget must be an object"
      end

      permitted = raw.permit(:key, :collapsed, :allow_duplicate).to_h
      %i[layout settings].each do |nested_key|
        next unless raw.key?(nested_key)

        nested = raw[nested_key]
        permitted[nested_key] = nested.respond_to?(:to_unsafe_h) ? nested.to_unsafe_h : nested
      end
      permitted
    end

    def render_validation_error(error)
      render json: { error: "validation_failed", message: error.message }, status: :unprocessable_entity
    end
end
