require "test_helper"

# A failed assistant turn must be announced (role=alert), styled with design
# system tokens rather than raw palette colours (so it reads in dark mode and
# meets contrast), and keep its retry action.
class ChatsErrorViewTest < ActionView::TestCase
  test "renders the failure as a live design-system alert with a retry" do
    chat = Chat.create!(user: users(:family_admin), title: "Broken", error: "upstream timed out")

    html = render(partial: "chats/error", locals: { chat: chat })
    fragment = Nokogiri::HTML.fragment(html)
    alert = fragment.at("##{chat.error_target}")

    assert alert, "expected the error container with the chat's error target id"
    assert_equal "alert", alert["role"]
    assert_includes html, chat.presentable_error_message
    assert fragment.at("form[action='#{retry_chat_path(chat)}']"), "expected the retry form"
    assert_no_match(/\b(bg|text|border)-red-\d+/, html, "raw palette classes are not design tokens")
  end
end
