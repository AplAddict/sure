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

  test "menu choices render as removable bubbles, not text in the box" do
    get new_chat_url
    assert_response :success

    # One bubble template per kind, each with a remove control and no preset text.
    %w[mention range prompt].each do |kind|
      assert_select "template[data-chat-composer-target='chipTemplate'][data-kind='#{kind}']", count: 1
    end
    assert_select "[data-chat-composer-target='chips']", count: 1
    assert_select "template [data-chip-remove]", count: 3

    # Items insert as bubbles (kind param), never with the old direct-to-textarea mode.
    assert_select "[data-chat-composer-kind-param='range']"
    assert_select "[data-chat-composer-kind-param='prompt']"
    assert_select "[data-chat-composer-mode-param]", count: 0
    assert_select "form[data-action~='submit->chat-composer#serialize']"
    assert_select "textarea[data-action~='keydown->chat-composer#backspace']"
  end
end
