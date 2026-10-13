require "test_helper"

class NavItemViewTest < ActionView::TestCase
  test "active nav item carries aria-current=\"page\"" do
    html = render(partial: "layouts/shared/nav_item", locals: {
      name: "Transactions",
      path: "/transactions",
      icon: "credit-card",
      icon_custom: false,
      active: true
    })

    assert_includes html, "aria-current=\"page\""
  end

  test "inactive nav item omits aria-current" do
    html = render(partial: "layouts/shared/nav_item", locals: {
      name: "Transactions",
      path: "/transactions",
      icon: "credit-card",
      icon_custom: false,
      active: false
    })

    assert_not_includes html, "aria-current"
  end

  test "More keeps overflow routes, badges and selected state in touch-sized rows" do
    html = Nokogiri::HTML.fragment(render(partial: "layouts/shared/mobile_more_nav", locals: {
      items: [
        { name: "Events", path: "/bills", icon: "calendar", icon_custom: false, active: true, preview: true },
        { name: "Assistant", path: "/chats", icon: "icon-assistant", icon_custom: true, active: false }
      ]
    }))

    assert_select html, "[data-testid=mobile-more-nav][data-controller=dialog-trigger]"
    assert_select html, "button[aria-haspopup=dialog][aria-expanded=false][aria-controls=mobile-more-nav-dialog][data-active=true][class*='min-h-11']",
      text: I18n.t("layouts.application.nav.more")
    assert_select html, "dialog#mobile-more-nav-dialog[data-testid=mobile-more-nav-dialog]"
    assert_select html, "a[href='/bills'][aria-current=page][class*='min-h-11']", text: /Events/
    assert_select html, "a[href='/chats']:not([aria-current])", text: /Assistant/
    assert_select html, "a[href='/bills'] [title=?]", I18n.t("shared.preview")
  end
end
