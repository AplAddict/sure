require "application_system_test_case"
require_relative "../support/dashboard_visual_qa_fixture"

# A real browser contract for the widget dashboard. The fixture is deliberately
# synthetic and test-only: it has analyzed bullish/bearish/neutral stories, so
# a passing test proves the rendered sentiment state rather than a provider
# response or a production member's saved layout.
class DashboardVisualQaTest < ApplicationSystemTestCase
  include DashboardVisualQaFixture

  PHONE = [ 375, 812 ].freeze
  SHOTS = Rails.root.join("tmp/screenshots/dashboard-visual-qa")

  setup do
    @user = users(:family_admin)
    sign_in @user
    @qa = build_dashboard_visual_qa_fixture!(user: @user)
    FileUtils.mkdir_p(SHOTS)
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
    portfolio_value_cards = all("section[data-widget-key]").select { |card| card.text.include?("Portfolio value") }
    assert_equal [ "portfolio.pulse" ], portfolio_value_cards.map { |card| card["data-widget-key"] }

    save_screenshot SHOTS.join("desktop.png")
    find("section[data-widget-key='research.news']").native.save_screenshot(SHOTS.join("desktop-news.png"))
    find("section[data-widget-key='portfolio.top_holdings']").native.save_screenshot(SHOTS.join("desktop-top-holdings.png"))
    assert_no_document_overflow("desktop dashboard")
  end

  test "phone dashboard has no Investments tab, a compact page switcher, and room above the bottom bar" do
    page.current_window.resize_to(*PHONE)
    visit root_url(page: @qa.fetch(:page_id))

    assert_selector "section[data-widget-key='research.news']", visible: :all
    labels = all("[data-testid=mobile-bottom-nav-items] li a p, [data-testid=mobile-bottom-nav-items] li button p").map(&:text)
    assert_includes labels, "Home"
    assert_not_includes labels, I18n.t("layouts.application.nav.investments")
    assert_selector "[data-testid=dashboard-page-switcher]", visible: true

    nav_height = page.evaluate_script("document.querySelector('[data-testid=mobile-bottom-nav]').getBoundingClientRect().height")
    padding = page.evaluate_script("parseFloat(getComputedStyle(document.querySelector('#main')).paddingBottom)")
    assert_operator padding, :>=, nav_height - 1, "main must reserve at least the bottom bar height so the last card stays reachable"

    save_screenshot SHOTS.join("phone.png")
    find("section[data-widget-key='research.news']").native.save_screenshot(SHOTS.join("phone-news.png"))
    find("section[data-widget-key='research.news']").assert_text I18n.t("pages.dashboard.settings.options.sentiment.bullish")
    assert_no_document_overflow("phone dashboard")
  end

  private

  def assert_no_document_overflow(label)
    widths = page.evaluate_script("({ document: document.documentElement.scrollWidth, viewport: window.innerWidth })")
    assert_operator widths.fetch("document"), :<=, widths.fetch("viewport"), "#{label} must not scroll horizontally"
  end
end
