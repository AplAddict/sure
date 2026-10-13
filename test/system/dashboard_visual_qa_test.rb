require "application_system_test_case"
require_relative "../support/dashboard_visual_qa_fixture"

# A real browser contract for the widget dashboard. The fixture is deliberately
# synthetic and test-only: it has analyzed bullish/bearish/neutral stories, so
# a passing test proves the rendered sentiment state rather than a provider
# response or a production member's saved layout.
class DashboardVisualQaTest < ApplicationSystemTestCase
  include DashboardVisualQaFixture

  PHONE = [ 375, 812 ].freeze

  setup do
    @user = users(:family_admin)
    @qa = build_dashboard_visual_qa_fixture!(user: @user)
    sign_in @user
  end

  teardown { restore_dashboard_visual_qa_network_guard! }

  test "desktop dashboard renders analyzed sentiment without duplicating the portfolio total" do
    visit root_url(page: @qa.fetch(:page_id))

    within "section[data-widget-key='research.news']" do
      assert_text "QA Alpha beats fictional estimates"
      assert_text "QA Beta faces fictional headwinds"
      assert_text "QA Gamma stays neutral"
      assert_text I18n.t("pages.dashboard.settings.options.sentiment.bullish")
      assert_text I18n.t("pages.dashboard.settings.options.sentiment.bearish")
      assert_text I18n.t("pages.dashboard.settings.options.sentiment.neutral")
    end
    within "section[data-widget-key='portfolio.top_holdings']" do
      assert_text I18n.t("pages.dashboard.granular_data.top_share")
      assert_no_text "Portfolio value"
    end

    save_screenshot Rails.root.join("tmp/screenshots/dashboard-visual-qa/desktop.png")
    assert_no_document_overflow("desktop dashboard")
  end

  test "phone dashboard keeps the sentiment widget and main content above the bottom bar" do
    page.current_window.resize_to(*PHONE)
    visit root_url(page: @qa.fetch(:page_id))

    assert_selector "section[data-widget-key='research.news']", visible: true
    assert_text "QA Alpha beats fictional estimates"
    main = page.evaluate_script("document.querySelector('#main').getBoundingClientRect()")
    nav = page.evaluate_script("document.querySelector('[data-testid=mobile-bottom-nav]').getBoundingClientRect()")
    assert_operator main["bottom"], :<=, nav["bottom"], "main must reserve the mobile bottom navigation area"
    save_screenshot Rails.root.join("tmp/screenshots/dashboard-visual-qa/phone.png")
    assert_no_document_overflow("phone dashboard")
  end

  private

  def assert_no_document_overflow(label)
    widths = page.evaluate_script("({ document: document.documentElement.scrollWidth, viewport: window.innerWidth })")
    assert_operator widths.fetch("document"), :<=, widths.fetch("viewport"), "#{label} must not scroll horizontally"
  end
end
