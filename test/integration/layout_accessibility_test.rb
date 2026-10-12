require "test_helper"

class LayoutAccessibilityTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
  end

  test "application layout renders skip-link pointing at #main and a <main> with id=\"main\"" do
    get root_path
    assert_response :ok

    skip_text = I18n.t("layouts.application.skip_to_main")

    assert_select "a[href=\"#main\"]", text: skip_text
    assert_select "main#main"
  end

  # The global research search is the only way to reach research for an unheld
  # ticker, so its trigger, field and submit must be labelled from the locale
  # rather than literal English, on both the mobile and the desktop surface.
  test "global research search is labelled from the locale on every surface" do
    get root_path
    assert_response :ok

    label = I18n.t("layouts.application.search.label")
    placeholder = I18n.t("layouts.application.search.placeholder")

    assert_select "button[data-search-toggle-target=trigger][aria-label=?][aria-expanded=false]", label, count: 2
    assert_select "input[type=search][name=q][aria-label=?][placeholder=?]", label, placeholder, count: 2
    assert_select "input[type=submit][value=?]", I18n.t("layouts.application.search.submit")
  end

  test "sidebar holdings metric picker is labelled from the locale" do
    get root_path
    assert_response :ok

    assert_select "select[name=sidebar_holding_metric][aria-label=?]", I18n.t("accounts.sidebar.metric_label"), minimum: 1 do
      %w[market_value price day_gain day_gain_pct gain gain_pct].each do |metric|
        assert_select "option[value=?]", metric, text: I18n.t("accounts.sidebar.metrics.#{metric}")
      end
    end
  end

  test "settings layout renders skip-link pointing at #main and a <main> with id=\"main\"" do
    get settings_profile_path
    assert_response :ok

    skip_text = I18n.t("layouts.application.skip_to_main")

    assert_select "a[href=\"#main\"]", text: skip_text
    assert_select "main#main"
  end
end
