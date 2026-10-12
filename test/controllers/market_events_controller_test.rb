require "test_helper"

class MarketEventsControllerTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    ensure_tailwind_build
    @owner = users(:family_admin)
  end

  test "requires authentication" do
    get market_events_path
    assert_redirected_to new_session_path
  end

  test "renders a localized heading and a labelled filter form" do
    sign_in @owner

    get market_events_path

    assert_response :success
    assert_select "turbo-frame#investment_workspace h1", text: I18n.t("market_events.index.title")
    assert_select "form[action=?]", market_events_path do
      %w[from to type].each do |field|
        assert_select "label[for=?]", field, text: I18n.t("market_events.index.filter.#{field}")
        assert_select "##{field}[name=?]", field
      end
      assert_select "option[value='']", text: I18n.t("market_events.index.types.all")
      MarketEventsController::EVENT_TYPES.each do |type|
        assert_select "option[value=?]", type, text: I18n.t("market_events.index.types.#{type}")
      end
      assert_select "input[type=submit][value=?][data-turbo-submits-with=?]",
                    I18n.t("market_events.index.filter.apply"), I18n.t("market_events.index.filter.applying")
    end
  end

  test "an empty range shows an empty state that leads to research" do
    sign_in @owner
    MarketCalendar::EventBuilder.any_instance.stubs(:events).returns([])

    get market_events_path(from: "2030-01-01", to: "2030-01-02")

    assert_response :success
    assert_match I18n.t("market_events.index.empty.title"), response.body
    assert_select "a[href=?]", research_search_path, text: I18n.t("market_events.index.empty.action")
  end
end
