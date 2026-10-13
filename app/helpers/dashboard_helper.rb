# Presentation helpers for the homepage dashboard and its page/widget shell.
module DashboardHelper
  def dashboard_widget_catalog(except: [])
    excluded = Array(except).map(&:to_s)
    preview_enabled = respond_to?(:preview_features_enabled?) && preview_features_enabled?

    Dashboard::WidgetRegistry.all.filter_map do |definition|
      next if excluded.include?(definition.key)
      next if definition.investment_required && !Current.user.investment_dashboard_access?
      next if definition.key == "home.insights_feed" && !preview_enabled

      entry = Dashboard::WidgetCatalog.fetch(definition.key)
      {
        key: definition.key,
        title: t(entry.title_key),
        description: t(entry.description_key, default: nil)
      }
    end
  end
end
