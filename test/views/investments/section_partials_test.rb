require "test_helper"

# Every collapsible block of the investment pages is a named partial with
# explicit locals, so a block can be rendered on its own (and later on another
# surface) without the page that first hosted it. These tests render each
# partial directly, outside its page, with the same objects the page passes.
class InvestmentSectionPartialsTest < ActionView::TestCase
  setup do
    @user = users(:family_admin)
    Current.session = Session.create!(user: @user)
  end

  test "decision center partials render their unavailable states from nil locals" do
    pulse = render(partial: "pages/decision_center/pulse", locals: { pulse: nil })
    assert_select Nokogiri::HTML.fragment(pulse), "[data-testid=idc-pulse-unavailable]"

    health = render(partial: "pages/decision_center/source_health", locals: { source_health: nil })
    assert_includes health, I18n.t("investment_decision_center.section_unavailable")

    actions = render(partial: "pages/decision_center/actions", locals: { actions: nil })
    assert_select Nokogiri::HTML.fragment(actions), "[data-testid=idc-actions-unavailable]"

    monitor = render(partial: "pages/decision_center/monitor", locals: { top_holdings: nil, center: InvestmentDecisionCenter.new(user: @user) })
    assert_select Nokogiri::HTML.fragment(monitor), "[data-testid=idc-monitor-unavailable]"
  end

  test "an empty action list is a real empty state, not an unavailable notice" do
    html = render(partial: "pages/decision_center/actions", locals: { actions: [] })

    assert_includes html, I18n.t("investment_decision_center.actions.none_title")
    assert_select Nokogiri::HTML.fragment(html), "[data-testid=idc-actions-unavailable]", count: 0
  end

  test "the harvest unavailable list names each position and its reason" do
    account = @user.family.accounts.create!(name: "Harvest Partial Brokerage", balance: 100, cash_balance: 0, currency: "USD", owner: @user,
                                            status: "active", accountable: Investment.new(subtype: "brokerage"))
    item = Struct.new(:ticker, :account, :reason).new("HPART", account, :cost_basis_unknown)

    html = render(partial: "tax_lot_reviews/harvest_unavailable", locals: { unavailable: [ item ] })

    assert_includes html, "HPART"
    assert_includes html, I18n.t("tax_loss_harvests.show.unavailable.cost_basis_unknown")
    assert_includes html, "Harvest Partial Brokerage"
  end

  test "the watchlist add form keeps what the member typed and shows its errors" do
    entry = @user.research_watchlist_entries.new(status: "researching", priority: 2)
    entry.errors.add(:base, "Ticker is unknown")

    html = render(partial: "research_watchlist_entries/add", locals: { entry: entry, typed_ticker: "ZZQQX" })
    fragment = Nokogiri::HTML.fragment(html)

    assert_select fragment, "[data-testid=watchlist-add] [role=alert]", text: /Ticker is unknown/
    assert_select fragment, "input[name='research_watchlist_entry[ticker]'][value=ZZQQX]"
    assert_select fragment, "option[selected][value=researching]"
  end

  test "the watchlist saved list says when a filter hides everything" do
    html = render(partial: "research_watchlist_entries/saved",
                  locals: { entries: [], status_counts: { "watching" => 1 }, status_filter: "ready", failed_entry: nil, fundamentals: {} })

    assert_includes html, I18n.t("research_watchlist_entries.index.empty_filtered")
    assert_select Nokogiri::HTML.fragment(html), "[data-testid=watchlist-filters] a[aria-current=true]", text: /Ready/
  end

  test "the sections shell renders every definition through its partial" do
    sections = InvestmentSections.new(namespace: "decision", user: @user, definitions: [
      { key: "pulse", title: "Pulse", partial: "pages/decision_center/pulse", locals: { pulse: nil } },
      { key: "actions", title: "Actions", partial: "pages/decision_center/actions", locals: { actions: [] }, flush: true }
    ])

    html = render(partial: "investments/sections", locals: { sections: sections, namespace: "decision",
                                                             url: "/portfolio/sections/decision", preference_key: "investments_decision" })
    fragment = Nokogiri::HTML.fragment(html)

    assert_equal %w[pulse actions], fragment.css("[data-reports-sortable-target=section]").map { |node| node["data-section-key"] }
    assert_select fragment, "[data-section-key=pulse] [data-testid=idc-pulse-unavailable]"
    assert_select fragment, "[data-section-key=actions] [data-reports-section-target=content]:not(.p-4)"
  end
end
