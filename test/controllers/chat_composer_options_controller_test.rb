require "test_helper"

class ChatComposerOptionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other = users(:family_member)
    sign_in @user

    @private = Account.create!(
      family: @other.family, owner: @other, accountable: Depository.new,
      name: "Zed Private Savings", currency: "USD", balance: 10, status: "active"
    )
  end

  test "lists only the signed-in user's accessible accounts" do
    get chat_composer_options_url, as: :json
    assert_response :success

    body = response.parsed_body
    assert_includes body["accounts"], @user.accessible_accounts.visible.first.name
    assert_not_includes body["accounts"], "Zed Private Savings"
    assert_not_includes response.body, "Zed Private Savings"
  end

  test "accounts are grouped by type and only include the user's own" do
    get chat_composer_options_url, as: :json
    groups = response.parsed_body["account_groups"]

    assert_kind_of Hash, groups
    assert groups.values.flatten.any?
    assert_equal response.parsed_body["accounts"].sort, groups.values.flatten.sort
    assert_not_includes groups.values.flatten, "Zed Private Savings"
    assert_equal groups.keys, groups.keys.sort_by { |k| ChatComposerOptionsController::ACCOUNT_GROUPS.keys.index(k) }

    sign_in @other
    get chat_composer_options_url, as: :json
    assert_includes response.parsed_body["account_groups"]["depository"], "Zed Private Savings"
  end

  test "another member sees their own private account" do
    sign_in @other
    get chat_composer_options_url, as: :json

    assert_includes response.parsed_body["accounts"], "Zed Private Savings"
  end

  test "requires AI to be enabled for the user" do
    @user.update!(ai_enabled: false)
    get chat_composer_options_url, as: :json

    assert_response :forbidden
  end

  test "requires sign in" do
    delete session_url(Current.session)
    get chat_composer_options_url, as: :json

    assert_response :redirect
  end

  test "composer renders working buttons and no disabled placeholders" do
    get new_chat_url
    assert_response :success

    assert_select "[data-controller~='chat-composer']"
    assert_select "button[disabled][title='Coming soon']", count: 0
    assert_select "[data-chat-composer-menu-param]", count: 3
    assert_select "[data-menu='mentions'] input[type=search]"
  end

  test "mention menu declares a label for every account group" do
    get new_chat_url
    ChatComposerOptionsController::ACCOUNT_GROUPS.each_key do |key|
      assert_select "[data-chat-composer-target='mentionList'][data-label-#{key.tr('_', '-')}]"
    end
  end

  test "time range button uses a clock icon, not a plus" do
    get new_chat_url
    assert_response :success

    button = css_select("button[aria-label='Add a time range']").first
    assert button, "time range button missing"

    # Lucide's clock: a circle with hands (M12 6v6l4 2). Lucide's plus is two lines (M5 12h14, M12 5v14).
    svg = button.to_s
    assert_includes svg, "M12 6v6l4 2", "expected the clock hands"
    assert_includes svg, "<circle", "expected the clock face"
    assert_not_includes svg, "M5 12h14", "plus icon must be gone"
  end

  test "menu choices render as removable bubbles, not text in the box" do
    get new_chat_url
    assert_response :success

    # One bubble template per kind, each with a remove control and no preset text.
    %w[mention range prompt file].each do |kind|
      assert_select "template[data-chat-composer-target='chipTemplate'][data-kind='#{kind}']", count: 1
    end
    assert_select "[data-chat-composer-target='chips']", count: 1
    assert_select "template [data-chip-remove]", count: 4

    # Items insert as bubbles (kind param), never with the old direct-to-textarea mode.
    assert_select "[data-chat-composer-kind-param='range']"
    assert_select "[data-chat-composer-kind-param='prompt']"
    assert_select "[data-chat-composer-mode-param]", count: 0
    assert_select "form[data-action~='submit->chat-composer#serialize']"
    assert_select "textarea[data-action~='keydown->chat-composer#backspace']"
  end
end
