class InvestmentSectionPreferencesController < ApplicationController
  def update
    namespace = params[:namespace].to_s
    return head :not_found unless User::INVESTMENT_SECTION_NAMESPACES.include?(namespace)

    known = InvestmentSections.valid_keys(namespace)
    prefix = "investments_#{namespace}"
    prefs = params.fetch(:preferences, {})

    order = prefs["#{prefix}_section_order"]
    order = Array(order).map(&:to_s).uniq & known if order.present?

    collapsed = prefs["#{prefix}_collapsed_sections"]
    collapsed = if collapsed.respond_to?(:to_unsafe_h)
      collapsed.to_unsafe_h.slice(*known).transform_values { |value| ActiveModel::Type::Boolean.new.cast(value) == true }
    end

    if Current.user.update_investment_sections(namespace, order: order.presence, collapsed: collapsed.presence)
      head :ok
    else
      head :unprocessable_entity
    end
  end

  # Back to the default layout for this page, for the signed-in member only.
  def destroy
    namespace = params[:namespace].to_s
    return head :not_found unless User::INVESTMENT_SECTION_NAMESPACES.include?(namespace)

    Current.user.reset_investment_sections(namespace) ? head(:ok) : head(:unprocessable_entity)
  end
end
