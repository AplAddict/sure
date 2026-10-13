# Presentation helpers for the homepage dashboard and its page/widget shell.
module DashboardHelper
  def dashboard_widget_catalog(except: [], existing: [])
    excluded = Array(except).map { |key| Dashboard::WidgetRegistry.canonical_key(key) }
    existing_keys = Array(existing).map { |key| Dashboard::WidgetRegistry.canonical_key(key) }
    preview_enabled = respond_to?(:preview_features_enabled?) && preview_features_enabled?

    entries = Dashboard::WidgetRegistry.all.filter_map do |definition|
      next if excluded.include?(definition.key)
      next if definition.investment_required && !Current.user.investment_dashboard_access?
      next if definition.key == "home.insights_feed" && !preview_enabled

      entry = Dashboard::WidgetCatalog.fetch(definition.key)
      {
        key: definition.key,
        title: t(entry.title_key),
        description: t(entry.description_key, default: nil),
        group: entry.group,
        added_count: existing_keys.count(definition.key),
        duplicate_type: existing_keys.include?(definition.key),
        settings: dashboard_catalog_widget_settings(definition)
      }
    end

    Dashboard::WidgetCatalog::GROUPS.filter_map do |group|
      widgets = entries.select { |entry| entry[:group] == group }
      { key: group, label: t("pages.dashboard.widget_groups.#{group}"), widgets: widgets } if widgets.any?
    end
  end

  def dashboard_setting_option_label(setting_key, value)
    t("pages.dashboard.settings.options.#{setting_key}.#{value}")
  end

  private
    def dashboard_catalog_widget_settings(definition)
      definition.settings.values.map do |setting|
        options = case setting.key
        when "account_id"
          dashboard_catalog_account_options
        when "security_id"
          dashboard_catalog_security_options
        else
          Array(setting.values).map { |value| [ dashboard_setting_option_label(setting.key, value), value ] }
        end

        {
          key: setting.key,
          type: setting.type,
          value: setting.default,
          default: setting.default,
          options: options,
          minimum: setting.minimum,
          maximum: setting.maximum
        }
      end
    end

    def dashboard_catalog_account_options
      @dashboard_catalog_account_options ||= Current.user.accessible_accounts.visible.where(accountable_type: %w[Investment Crypto]).order(:name).pluck(:name, :id).map { |name, id| [ name, id.to_s ] }
    end

    def dashboard_catalog_security_options
      @dashboard_catalog_security_options ||= begin
        held = Holding.where(account_id: Current.user.accessible_accounts.visible.select(:id)).select(:security_id)
        watched = Current.user.research_watchlist_entries.active.select(:security_id)
        Security.where(id: held).or(Security.where(id: watched)).order(:ticker).map { |security| [ "#{security.ticker} · #{security.name}", security.id.to_s ] }
      end
    end
end
