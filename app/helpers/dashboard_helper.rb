# Presentation helpers for the homepage dashboard and its page/widget shell.
module DashboardHelper
  # The widgets a homepage page can host, as the { key:, title: } hashes the
  # add-widget dialog lists. Keys are PagesController::DASHBOARD_SECTION_LAYOUTS
  # (the one registry of dashboard widgets), titles their existing translations;
  # `except:` drops the keys already on the page so they are not offered twice.
  def dashboard_widget_catalog(except: [])
    excluded = Array(except).map(&:to_s)

    PagesController::DASHBOARD_SECTION_LAYOUTS.keys.reject { |key| excluded.include?(key) }.map do |key|
      { key: key, title: t("pages.dashboard.#{key}.title") }
    end
  end
end
