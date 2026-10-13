require "test_helper"
require_relative "../support/dashboard_visual_qa_fixture"

# Browser availability differs between developer hosts and CI. This request-level
# companion proves the same synthetic fixture and rendered dashboard contract on
# every test runner; DashboardVisualQaTest adds browser geometry/screenshots when
# Selenium is available.
class DashboardVisualQaFixtureTest < ActionDispatch::IntegrationTest
  include DashboardVisualQaFixture

  setup do
    @user = users(:family_admin)
    sign_in @user
    @qa = build_dashboard_visual_qa_fixture!(user: @user)
  end

  teardown { restore_dashboard_visual_qa_network_guard! }

  test "renders analyzed tones from local synthetic evidence without provider HTTP" do
    get root_path(page: @qa.fetch(:page_id))

    assert_response :success
    assert_select "section[data-widget-key='research.news']", text: /QA Alpha beats fictional estimates/ do
      assert_select "section", text: /#{Regexp.escape(I18n.t("pages.dashboard.settings.options.sentiment.bullish"))}/
      assert_select "section", text: /#{Regexp.escape(I18n.t("pages.dashboard.settings.options.sentiment.bearish"))}/
      assert_select "section", text: /#{Regexp.escape(I18n.t("pages.dashboard.settings.options.sentiment.neutral"))}/
    end
    assert_select "section[data-widget-key='portfolio.top_holdings']", text: /#{Regexp.escape(I18n.t("pages.dashboard.granular_data.top_share"))}/
    assert_not_requested :any, /^(?!http:\/\/(localhost|127\.0\.0\.1)|https?:\/\/example\.test)/
  end
end
