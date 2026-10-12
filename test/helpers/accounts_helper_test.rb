require "test_helper"

class AccountsHelperTest < ActionView::TestCase
  setup { Current.stubs(:user).returns(users(:family_admin)) }

  test "sidebar tab cache key version changes when holdings sidebar markup changes" do
    key = account_sidebar_tabs_cache_key(family: Current.user.family, active_tab: "holdings", mobile: false)

    assert_includes key.first, "account_sidebar_tabs_v5"
  end

  test "sidebar cache key changes when the default account order changes" do
    Current.user.update!(default_account_order: "name_asc")
    before = account_sidebar_tabs_cache_key(family: Current.user.family, active_tab: "all", mobile: false)

    Current.user.update!(default_account_order: "balance_desc")
    after = account_sidebar_tabs_cache_key(family: Current.user.family, active_tab: "all", mobile: false)

    assert_not_equal before, after
  end
end
