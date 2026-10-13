require "test_helper"

class DashboardWidgetInstancesTest < ActionDispatch::IntegrationTest
  NEW_WIDGET_KEYS = %w[
    portfolio.day_movers portfolio.allocation portfolio.largest_position
    portfolio.account_balances portfolio.cash_liquidity portfolio.holdings_count
    income.by_type income.top_months income.fx_gaps
    tax.term_split tax.unrealized_by_holding tax.harvest_loss_total tax.fx_unavailable
    tax.long_term_window options.expiration_window options.dte_distribution
    options.by_underlying options.unmeasured research.watchlist_snapshot
    research.event_countdown research.news
  ].freeze

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: {})
    sign_in @user
    @page = @user.create_dashboard_page!("Instances")
  end

  test "same type instances keep immutable ids order and settings independently" do
    account = accounts(:investment)

    post page_widgets_path(@page.fetch("id")), params: {
      widget: { key: "portfolio.allocation", settings: { scope: "overall", account_id: nil, rows: 5, grouping: "asset_class" } }
    }, as: :json
    assert_response :created
    overall = response.parsed_body.fetch("widget")

    post page_widgets_path(@page.fetch("id")), params: {
      widget: { key: "portfolio.allocation", settings: { scope: "account", account_id: account.id, rows: 8, grouping: "sector" } }
    }, as: :json
    assert_response :created
    scoped = response.parsed_body.fetch("widget")

    assert_match User::DASHBOARD_WIDGET_INSTANCE_ID, overall.fetch("id")
    assert_match User::DASHBOARD_WIDGET_INSTANCE_ID, scoped.fetch("id")
    assert_not_equal overall.fetch("id"), scoped.fetch("id")

    patch page_widget_path(@page.fetch("id"), overall.fetch("id")), params: {
      widget: { settings: overall.fetch("settings").merge("rows" => 3) }
    }, as: :json
    assert_response :success

    patch order_page_widgets_path(@page.fetch("id")), params: { instance_ids: [ scoped.fetch("id"), overall.fetch("id") ] }, as: :json
    assert_response :success
    assert_equal [ scoped.fetch("id"), overall.fetch("id") ], response.parsed_body.dig("page", "widgets").map { |widget| widget.fetch("id") }

    delete page_widget_path(@page.fetch("id"), scoped.fetch("id")), as: :json
    assert_response :no_content
    remaining = @user.reload.dashboard_pages.find { |page| page["id"] == @page.fetch("id") }.fetch("widgets").sole
    assert_equal overall.fetch("id"), remaining.fetch("id")
    assert_equal 3, remaining.dig("settings", "rows")
    assert_equal "overall", remaining.dig("settings", "scope")
  end

  test "identical duplicate requires explicit confirmation" do
    post page_widgets_path(@page.fetch("id")), params: { widget: { key: "income.summary" } }, as: :json
    assert_response :created
    original = @user.reload.preferences.deep_dup

    post page_widgets_path(@page.fetch("id")), params: { widget: { key: "income.summary" } }, as: :json
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences

    post page_widgets_path(@page.fetch("id")), params: { widget: { key: "income.summary", allow_duplicate: true } }, as: :json
    assert_response :created

    post page_widgets_path(@page.fetch("id")), params: {
      widget: {
        key: "portfolio.allocation",
        settings: { scope: "overall", account_id: "", rows: 5, grouping: "asset_class" }
      }
    }, as: :json
    assert_response :created
    assert_nil response.parsed_body.dig("widget", "settings", "account_id")

    post page_widgets_path(@page.fetch("id")), params: {
      widget: {
        key: "portfolio.allocation",
        settings: { scope: "overall", account_id: nil, rows: 5, grouping: "asset_class" }
      }
    }, as: :json
    assert_response :unprocessable_entity
  end

  test "security instances for AAPL and MSFT render without DOM collisions" do
    Holding.create!(
      account: accounts(:investment), security: securities(:msft), date: Date.current,
      qty: 2, price: 410, amount: 820, currency: "USD"
    )

    [ securities(:aapl), securities(:msft) ].each do |security|
      post page_widgets_path(@page.fetch("id")), params: {
        widget: { key: "portfolio.security_snapshot", settings: { scope: "security", security_id: security.id } }
      }, as: :json
      assert_response :created
    end

    get root_path(page: @page.fetch("id"))
    assert_response :success
    sections = css_select("section[data-widget-key='portfolio.security_snapshot']")
    assert_equal 2, sections.size
    assert_equal 2, sections.map { |section| section["data-widget-instance-id"] }.uniq.size
    ids = css_select("#dashboard_sections [id]").map { |node| node["id"] }
    assert_equal ids.uniq, ids
    assert_match(/AAPL/, response.body)
    assert_match(/MSFT/, response.body)
  end

  test "overall and account instances render independently without account leakage" do
    Holding.create!(
      account: accounts(:crypto), security: securities(:msft), date: Date.current,
      qty: 2, price: 410, amount: 820, currency: "USD"
    )
    overall = @user.add_dashboard_widget!(
      @page.fetch("id"), "portfolio.allocation",
      settings: { scope: "overall", account_id: nil, rows: 5, grouping: "security" }
    )
    scoped = @user.add_dashboard_widget!(
      @page.fetch("id"), "portfolio.allocation",
      settings: { scope: "account", account_id: accounts(:investment).id, rows: 5, grouping: "security" }
    )

    get root_path(page: @page.fetch("id"))

    assert_response :success
    overall_section = css_select("section[data-widget-instance-id='#{overall.fetch("id")}']").sole
    scoped_section = css_select("section[data-widget-instance-id='#{scoped.fetch("id")}']").sole
    assert_includes overall_section.text, "AAPL"
    assert_includes overall_section.text, "MSFT"
    assert_includes scoped_section.text, "AAPL"
    assert_not_includes scoped_section.text, "MSFT"
    assert_includes scoped_section.text, accounts(:investment).name
  end

  test "duplicate chart widgets use instance ids for every rendered DOM id" do
    first = @user.add_dashboard_widget!(@page.fetch("id"), "home.net_worth_chart")
    second = @user.add_dashboard_widget!(@page.fetch("id"), "home.net_worth_chart", allow_duplicate: true)

    get root_path(page: @page.fetch("id"))

    assert_response :success
    ids = css_select("#dashboard_sections [id]").map { |node| node["id"] }
    assert_equal ids.uniq, ids
    assert_select "#widget-#{first.fetch("id")}-chart", count: 1
    assert_select "#widget-#{second.fetch("id")}-chart", count: 1
  end

  test "unknown malformed and inaccessible settings are atomic" do
    widget = @user.add_dashboard_widget!(@page.fetch("id"), "portfolio.allocation")
    original = @user.reload.preferences.deep_dup
    inaccessible_account = accounts(:depository)

    invalid_settings = [
      widget.fetch("settings").merge("unknown" => true),
      widget.fetch("settings").merge("rows" => "5"),
      widget.fetch("settings").merge("scope" => "account", "account_id" => inaccessible_account.id),
      widget.fetch("settings").merge("scope" => "account", "account_id" => "not-an-id"),
      widget.fetch("settings").merge("scope" => "account", "account_id" => inaccessible_account.id, "security_id" => "extra")
    ]

    invalid_settings.each do |settings|
      patch page_widget_path(@page.fetch("id"), widget.fetch("id")), params: { widget: { settings: settings } }, as: :json
      assert_response :unprocessable_entity
      assert_equal original, @user.reload.preferences
    end
  end

  test "inaccessible security is rejected without exposing another symbol" do
    original = @user.reload.preferences.deep_dup

    post page_widgets_path(@page.fetch("id")), params: {
      widget: { key: "portfolio.security_snapshot", settings: { scope: "security", security_id: securities(:msft).id } }
    }, as: :json

    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences
  end

  test "account portfolio review applies editable account scope atomically" do
    account = accounts(:investment)

    post pages_path, params: { page: { name: "Account Review", template: "account_portfolio_review", account_id: account.id } }, as: :json

    assert_response :created
    page = response.parsed_body.fetch("page")
    scoped = page.fetch("widgets").select do |widget|
      Dashboard::WidgetRegistry.fetch(widget.fetch("key")).settings.key?("account_id")
    end
    assert scoped.any?
    assert scoped.all? { |widget| widget.dig("settings", "scope") == "account" && widget.dig("settings", "account_id") == account.id }
    assert_equal page.fetch("widgets").size, page.fetch("widgets").map { |widget| widget.fetch("id") }.uniq.size

    original = @user.reload.preferences.deep_dup
    post pages_path, params: { page: { name: "Wrong account", template: "account_portfolio_review", account_id: accounts(:depository).id } }, as: :json
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences
  end

  test "all new widget types render with unique instance DOM ids" do
    overflow_page = @user.create_dashboard_page!("More widgets")
    NEW_WIDGET_KEYS.each_with_index do |key, index|
      page_id = index < User::MAX_DASHBOARD_WIDGETS ? @page.fetch("id") : overflow_page.fetch("id")
      @user.add_dashboard_widget!(page_id, key)
    end

    pages_with_widgets = @user.reload.dashboard_pages.select do |page|
      [ @page.fetch("id"), overflow_page.fetch("id") ].include?(page.fetch("id")) && page.fetch("widgets").any?
    end
    pages_with_widgets.each do |page|
      get root_path(page: page.fetch("id"))
      assert_response :success
      ids = css_select("#dashboard_sections [id]").map { |node| node["id"] }
      assert_equal ids.uniq, ids
    end

    rendered = @user.reload.dashboard_pages
      .select { |page| [ @page.fetch("id"), overflow_page.fetch("id") ].include?(page.fetch("id")) }
      .flat_map { |page| page.fetch("widgets") }
    assert_equal NEW_WIDGET_KEYS.sort, rendered.map { |widget| widget.fetch("key") }.sort
    assert_equal rendered.size, rendered.map { |widget| widget.fetch("id") }.uniq.size
  end

  test "all new widget types render honest empty or unavailable states without failing" do
    empty_user = users(:empty)
    empty_user.update!(preferences: {})
    empty_user.family.accounts.create!(
      name: "Empty investment", balance: 0, cash_balance: 0, currency: empty_user.family.currency,
      accountable: Investment.new, owner: empty_user
    )
    sign_in empty_user
    first_page = empty_user.create_dashboard_page!("Empty widgets A")
    second_page = empty_user.create_dashboard_page!("Empty widgets B")
    NEW_WIDGET_KEYS.each_with_index do |key, index|
      page_id = index < User::MAX_DASHBOARD_WIDGETS ? first_page.fetch("id") : second_page.fetch("id")
      empty_user.add_dashboard_widget!(page_id, key)
    end

    pages_with_widgets = empty_user.reload.dashboard_pages.select do |page|
      [ first_page.fetch("id"), second_page.fetch("id") ].include?(page.fetch("id")) && page.fetch("widgets").any?
    end
    pages_with_widgets.each do |page|
      get root_path(page: page.fetch("id"))
      assert_response :success
      assert_select "section[data-widget-key]" do |sections|
        sections.each do |section|
          assert section.at_css("[data-testid='granular-investment-widget'], [role='status']"), "expected an honest state for #{section['data-widget-key']}"
        end
      end
    end
  end

  test "news settings reject malformed bounds and inaccessible identifiers atomically" do
    widget = @user.add_dashboard_widget!(@page.fetch("id"), "research.news")
    outsider = users(:empty)
    hidden_account = outsider.family.accounts.create!(name: "Hidden news", balance: 1, cash_balance: 0, currency: "USD", owner: outsider, accountable: Investment.new)
    hidden_security = Security.create!(ticker: "NWHID", exchange_mic: "XNAS", name: "Hidden News")
    hidden_account.holdings.create!(security: hidden_security, date: Date.current, qty: 1, price: 1, amount: 1, currency: "USD")
    original = @user.reload.preferences.deep_dup
    base = widget.fetch("settings")
    invalid = [
      base.merge("rows" => 2),
      base.merge("rows" => 13),
      base.merge("rows" => "5"),
      base.merge("sort" => "popular"),
      base.merge("scope" => "account", "account_id" => hidden_account.id.to_s),
      base.merge("scope" => "security", "security_id" => hidden_security.id.to_s),
      base.merge("unknown" => "value")
    ]

    invalid.each do |settings|
      patch page_widget_path(@page.fetch("id"), widget.fetch("id")), params: { widget: { settings: settings } }, as: :json
      assert_response :unprocessable_entity
      assert_equal original, @user.reload.preferences
    end

    get root_path(page: @page.fetch("id"), scope: "security", security_id: hidden_security.id)
    assert_response :success
    assert_equal original, @user.reload.preferences

    patch page_widget_path(@page.fetch("id"), widget.fetch("id")), params: {
      widget: { settings: base.merge("scope" => "account", "account_id" => accounts(:investment).id.to_s) }
    }, as: :json
    assert_response :success
    patch page_widget_path(@page.fetch("id"), widget.fetch("id")), params: {
      widget: { settings: Dashboard::WidgetRegistry.fetch("research.news").default_settings }
    }, as: :json
    assert_response :success
    cleared_page = @user.reload.dashboard_pages.find { |page| page.fetch("id") == @page.fetch("id") }
    cleared = cleared_page.fetch("widgets").find { |entry| entry.fetch("id") == widget.fetch("id") }.fetch("settings")
    assert_equal Dashboard::WidgetRegistry.fetch("research.news").default_settings, cleared
    assert_equal "overall", cleared["scope"]
  end

  test "legacy news preferences read forward to independent canonical instances" do
    @user.update!(preferences: {
      "dashboard_pages" => [
        {
          "id" => "home", "name" => "Home",
          "widgets" => [
            { "id" => "w_aaaaaaaaaaaa", "key" => "home.ticker_news", "collapsed" => false, "layout" => { "col_width" => 12, "height" => 3 }, "settings" => { "rows" => 8 } },
            { "id" => "w_bbbbbbbbbbbb", "key" => "research.news_sentiment", "collapsed" => false, "layout" => { "col_width" => 12, "height" => 3 }, "settings" => { "rows" => 3 } }
          ]
        }
      ],
      "dashboard_current_page" => "home"
    })
    original = @user.reload.preferences.deep_dup

    widgets = @user.dashboard_pages.first.fetch("widgets")

    assert_equal %w[research.news research.news], widgets.map { |widget| widget.fetch("key") }
    assert_equal [ 8, 3 ], widgets.map { |widget| widget.dig("settings", "rows") }
    assert_equal [ "all", "sentiment" ], widgets.map { |widget| widget.dig("settings", "filter") }
    assert_equal original, @user.reload.preferences
  end

  test "same-type news instances keep scope filter period sort rows and density independent" do
    account = @user.family.accounts.create!(name: "News account", balance: 200, cash_balance: 0, currency: "USD", owner: @user, accountable: Investment.new)
    first_security = Security.create!(ticker: "NWONE", exchange_mic: "XNAS", name: "News One")
    second_security = Security.create!(ticker: "NWTWO", exchange_mic: "XNAS", name: "News Two")
    account.holdings.create!(security: first_security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD")
    account.holdings.create!(security: second_security, date: Date.current, qty: 1, price: 100, amount: 100, currency: "USD")
    alpha_title = "Alpha measured headline"
    alpha_source = "Fixture Wire"
    digest = Digest::SHA256.hexdigest([ alpha_source, alpha_title ].join("\u0000"))
    SecurityHeadlineAnalysis.create!(security: first_security, status: "current", source_digest: Digest::SHA256.hexdigest("fixture"), analyzed_at: Time.current, payload: { "articleTones" => { digest => { "tone" => "bullish" } } })
    SecurityResearchSnapshot.create!(
      security: first_security, status: "current", generated_at: Time.current, imported_at: Time.current,
      payload: { "news" => [
        { "title" => "Zeta unmeasured headline", "link" => "https://example.com/zeta", "source" => alpha_source, "description" => "Zeta detail", "published" => Date.current.iso8601 },
        { "title" => alpha_title, "link" => "https://example.com/alpha", "source" => alpha_source, "description" => "Alpha detail", "published" => 2.days.ago.iso8601 },
        { "title" => "Old measured headline", "link" => "https://example.com/old", "source" => alpha_source, "published" => 2.years.ago.iso8601 }
      ] }
    )
    SecurityResearchSnapshot.create!(
      security: second_security, status: "current", generated_at: Time.current, imported_at: Time.current,
      payload: { "news" => [ { "title" => "Second security headline", "link" => "https://example.com/second", "source" => "Other Wire", "published" => Date.current.iso8601 } ] }
    )

    filtered = @user.add_dashboard_widget!(@page.fetch("id"), "research.news", settings: {
      scope: "security", security_id: first_security.id.to_s, period: "1m", rows: 3,
      sort: "title", filter: "sentiment", density: "detail", sentiment: "bullish"
    })
    separate = @user.add_dashboard_widget!(@page.fetch("id"), "research.news", settings: {
      scope: "security", security_id: second_security.id.to_s, period: "all", rows: 3,
      sort: "newest", filter: "all", density: "compact", sentiment: "all"
    })

    get root_path(page: @page.fetch("id"))

    assert_response :success
    filtered_section = css_select("section[data-widget-instance-id='#{filtered.fetch("id")}']").sole
    separate_section = css_select("section[data-widget-instance-id='#{separate.fetch("id")}']").sole
    assert_includes filtered_section.text, alpha_title
    assert_includes filtered_section.text, "Alpha detail"
    assert_not_includes filtered_section.text, "Zeta unmeasured headline"
    assert_not_includes filtered_section.text, "Old measured headline"
    assert_includes separate_section.text, "Second security headline"
    assert_not_includes separate_section.text, alpha_title
    assert_equal 2, css_select("section[data-widget-key='research.news']").size
    assert_select "section[data-widget-key='research.news'] details[data-controller='widget-settings'][data-action*='keydown.esc->widget-settings#close'] summary[aria-expanded=false]", count: 2
    assert_select "section[data-widget-key='research.news'] [data-dashboard-pages-target=error][data-error-scope=form]", count: 2
    assert_select "[data-testid=dashboard-page-alert][data-error-scope=page]", count: 1
  end

  test "canonical news fields and current tones agree between widget and news page" do
    security = securities(:aapl)
    title = "Shared canonical news row"
    source = "Shared Wire"
    digest = Digest::SHA256.hexdigest([ source, title ].join("\u0000"))
    security.research_snapshot&.destroy!
    security.headline_analysis&.destroy!
    SecurityResearchSnapshot.create!(
      security: security, status: "current", generated_at: Time.current, imported_at: Time.current,
      payload: { "news" => [ { "title" => title, "link" => "https://example.com/shared", "source" => source, "category" => "markets", "published" => Time.current.iso8601 } ] }
    )
    SecurityHeadlineAnalysis.create!(
      security: security, status: "current", source_digest: Digest::SHA256.hexdigest("shared"), analyzed_at: Time.current,
      payload: { "articleTones" => { digest => { "tone" => "bullish" } } }
    )
    widget = @user.add_dashboard_widget!(@page.fetch("id"), "research.news")

    get root_path(page: @page.fetch("id"))
    widget_row = css_select("section[data-widget-instance-id='#{widget.fetch("id")}']").sole
    assert_includes widget_row.text, title
    assert_includes widget_row.text, I18n.t("pages.dashboard.settings.options.sentiment.bullish")

    get research_news_path(scope: "overall")
    assert_response :success
    assert_select "article", text: /#{Regexp.escape(title)}/ do |articles|
      assert_includes articles.sole.text, I18n.t("pages.dashboard.settings.options.sentiment.bullish")
    end
    assert_select "select[name=category] option[value=markets]", text: "Markets"
  end

  test "revoked account and security news scopes render unavailable without data" do
    member = users(:family_member)
    member.update!(preferences: {})
    account = member.family.accounts.create!(name: "Revocable News", owner: @user, currency: "USD", balance: 10, accountable: Investment.new)
    account.account_shares.create!(user: member, permission: "read_only")
    security = Security.create!(ticker: "RVKNEWS", exchange_mic: "XNAS", name: "Revoked News")
    account.holdings.create!(security: security, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    SecurityResearchSnapshot.create!(
      security: security, status: "current", generated_at: Time.current, imported_at: Time.current,
      payload: { "news" => [ { "title" => "Private revoked headline", "link" => "https://example.com/revoked", "source" => "Private Wire" } ] }
    )
    page = member.create_dashboard_page!("Revoked scopes")
    member.add_dashboard_widget!(page.fetch("id"), "research.news", settings: { scope: "account", account_id: account.id.to_s })
    member.add_dashboard_widget!(page.fetch("id"), "research.news", settings: { scope: "security", security_id: security.id.to_s }, allow_duplicate: true)
    account.account_shares.destroy_all
    assert_not member.accessible_accounts.exists?(account.id)
    sign_in member

    get root_path(page: page.fetch("id"))

    assert_response :success
    assert_select "section[data-widget-key='research.news'] [role=status]", count: 2, text: /#{Regexp.escape(I18n.t("pages.dashboard.widget_unavailable.scope_unavailable"))}/
    assert_not_includes response.body, "Private revoked headline"
  end

  test "legacy preferences read forward with stable instance ids" do
    @user.update!(preferences: {
      "dashboard_pages" => [
        {
          "id" => "home", "name" => "Home",
          "widgets" => [ { "key" => "home.balance_sheet", "collapsed" => false, "layout" => { "col_width" => 6, "height" => 4 } } ]
        }
      ],
      "dashboard_current_page" => "home"
    })

    first = @user.dashboard_pages.dig(0, "widgets", 0)
    second = @user.dashboard_pages.dig(0, "widgets", 0)

    assert_match User::DASHBOARD_WIDGET_INSTANCE_ID, first.fetch("id")
    assert_equal first.fetch("id"), second.fetch("id")
    assert_equal Dashboard::WidgetRegistry.fetch("home.balance_sheet").default_settings, first.fetch("settings")
    assert_not @user.reload.preferences.dig("dashboard_pages", 0, "widgets", 0).key?("id")
  end
end
