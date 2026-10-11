require "test_helper"

class InvestmentDecisionCenterTest < ActionDispatch::IntegrationTest
  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    ensure_tailwind_build
    @owner = users(:family_admin)
    @member = users(:family_member)
    @family = @owner.family

    @account = @family.accounts.create!(
      name: "Decision Brokerage", balance: 5_000, cash_balance: 1_000, currency: "USD", owner: @owner,
      status: "active", accountable: Investment.new(subtype: "brokerage")
    )
    @loser = Security.create!(ticker: "DCLOSS", exchange_mic: "XNAS", name: "Decision Loser")
    @account.holdings.create!(security: @loser, date: Date.current, qty: 10, price: 70, amount: 700,
                              currency: "USD", cost_basis: 100, cost_basis_source: "provider")
  end

  # ---- model ----

  test "available only when the member has investment accounts of their own" do
    assert InvestmentDecisionCenter.new(user: @owner).available?
    assert_not InvestmentDecisionCenter.new(user: users(:empty)).available?
  end

  test "actions surface harvestable losses and rank them" do
    actions = InvestmentDecisionCenter.new(user: @owner).actions

    harvest = actions.find { |a| a.kind == :harvest }
    assert harvest
    assert_equal 1, harvest.count
    assert_equal BigDecimal("300"), harvest.detail.amount
  end

  test "positions without cost basis are reported not counted" do
    nocb = Security.create!(ticker: "DCNOCB", exchange_mic: "XNAS")
    @account.holdings.create!(security: nocb, date: Date.current, qty: 5, price: 10, amount: 50, currency: "USD")

    center = InvestmentDecisionCenter.new(user: @owner)
    gap = center.actions.find { |a| a.kind == :cost_basis }

    assert gap
    assert_equal [ "DCNOCB" ], gap.detail
    assert_equal 1, center.actions.find { |a| a.kind == :harvest }.count
  end

  test "pulse flags stale holdings instead of presenting them as current" do
    stale_owner = users(:empty)
    account = stale_owner.family.accounts.create!(
      name: "Only Stale Brokerage", balance: 100, cash_balance: 0, currency: "USD", owner: stale_owner,
      status: "active", accountable: Investment.new(subtype: "brokerage")
    )
    account.holdings.create!(security: Security.create!(ticker: "DCSTALE", exchange_mic: "XNAS"), date: Date.current - 10,
                             qty: 1, price: 10, amount: 10, currency: "USD")

    pulse = InvestmentDecisionCenter.new(user: stale_owner).pulse

    assert pulse.stale
    assert_equal Date.current - 10, pulse.as_of
  end

  test "fresh holdings are not flagged stale" do
    assert_not InvestmentDecisionCenter.new(user: @owner).pulse.stale
  end

  test "one fresh account does not hide a stale one" do
    stale = @family.accounts.create!(
      name: "Stale Brokerage", balance: 100, cash_balance: 0, currency: "USD", owner: @owner,
      status: "active", accountable: Investment.new(subtype: "brokerage")
    )
    stale.holdings.create!(security: Security.create!(ticker: "DCOLD", exchange_mic: "XNAS"), date: Date.current - 20,
                           qty: 1, price: 10, amount: 10, currency: "USD")

    pulse = InvestmentDecisionCenter.new(user: @owner).pulse

    assert pulse.stale
    assert_equal Date.current - 20, pulse.as_of
  end

  test "source health reports snapshot freshness and known-basis coverage without treating missing data as zero" do
    center = InvestmentDecisionCenter.new(user: @owner)
    sources = center.source_health

    assert_equal "current", sources.find { |source| source.key == :holdings }.status
    assert_equal "current", sources.find { |source| source.key == :basis }.status

    sign_in @owner
    get root_path(view: "decision")
    assert_select "[data-testid=idc-source-health]", text: /Holdings snapshot/
    assert_select "[data-testid=idc-source-health]", text: /Cost basis coverage/
  end

  test "a section that raises degrades to unavailable instead of failing the page" do
    InvestmentDecisionCenter.any_instance.stubs(:build_actions).raises(StandardError, "boom")
    sign_in @owner
    get root_path(view: "decision")

    assert_response :success
    assert_select "[data-testid=idc-actions-unavailable]"
    assert_select "[data-testid=idc-pulse-unavailable]", count: 0
    assert_select "h2", text: /Nothing needs a decision/i, count: 0
  end

  test "a failed action list is nil, never an empty list that reads as nothing to do" do
    InvestmentDecisionCenter.any_instance.stubs(:build_actions).raises(StandardError, "boom")
    center = InvestmentDecisionCenter.new(user: @owner)

    assert_nil center.actions
    assert center.failed?(:actions)
  end

  test "a failed pulse leaves the other sections working" do
    InvestmentStatement.any_instance.stubs(:portfolio_value_money).raises(StandardError, "boom")
    sign_in @owner
    get root_path(view: "decision")

    assert_response :success
    assert_select "[data-testid=idc-pulse-unavailable]"
    assert_select "[data-testid=idc-actions-unavailable]", count: 0
    assert_select "[data-testid=holding-row], td a", text: "DCLOSS"
  end

  test "if the statement itself breaks the homepage still loads as the normal overview" do
    InvestmentDecisionCenter.any_instance.stubs(:statement).raises(StandardError, "boom")
    sign_in @owner
    get root_path(view: "decision")

    assert_response :success
    assert_not InvestmentDecisionCenter.new(user: @owner).available?
  end

  test "actions are cached per member and survive a round trip with their values intact" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    first = InvestmentDecisionCenter.new(user: @owner).actions
    TaxLossHarvest.expects(:new).never
    second = InvestmentDecisionCenter.new(user: @owner).actions

    assert_equal first.map { |a| [ a.kind, a.count, a.priority ] }, second.map { |a| [ a.kind, a.count, a.priority ] }
    harvest = second.find { |a| a.kind == :harvest }
    assert_equal BigDecimal("300"), harvest.detail.amount
    assert_equal "USD", harvest.detail.currency.iso_code
  ensure
    Rails.cache = original_cache
  end

  test "one member's cached actions are never served to another" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    InvestmentDecisionCenter.new(user: @owner).actions
    other = InvestmentDecisionCenter.new(user: users(:family_member))

    assert_not_equal InvestmentDecisionCenter.new(user: @owner).send(:actions_cache_key), other.send(:actions_cache_key)
  ensure
    Rails.cache = original_cache
  end

  test "the decision center links to the full holdings page" do
    sign_in @owner
    get root_path(view: "decision")

    assert_select "a[href=?]", portfolio_holdings_path
  end

  test "another member sees nothing of the owner's holdings" do
    center = InvestmentDecisionCenter.new(user: @member)

    assert_not center.available?
    assert_empty center.actions
    assert_empty center.top_holdings
  end

  # ---- homepage ----

  test "owner can switch to the decision center and sees only their data" do
    sign_in @owner
    get root_path(view: "decision")

    assert_response :success
    assert_select "h1", text: I18n.t("investment_decision_center.title")
    assert_match "DCLOSS", response.body
    assert_select "[aria-current='true']", text: I18n.t("investment_decision_center.switch.decision")
  end

  test "the overview shows the switch when the member has investments" do
    sign_in @owner
    get root_path

    assert_response :success
    assert_select "a[href=?]", root_path(view: "decision"), text: I18n.t("investment_decision_center.switch.decision")
  end

  test "a member with no investment accounts gets no switch and cannot force the view" do
    sign_in users(:empty).tap { |u| u.update!(onboarded_at: 1.day.ago) }
    get root_path(view: "decision")

    assert_response :success
    assert_select "a[href=?]", root_path(view: "decision"), count: 0
    assert_no_match(/#{I18n.t("investment_decision_center.title")}/, response.body)
  end

  test "family members never see each other's decision center" do
    sign_in @member
    get root_path(view: "decision")

    assert_response :success
    assert_no_match(/DCLOSS/, response.body)
    assert_no_match(/Decision Brokerage/, response.body)
  end

  test "the chosen view is remembered per user and does not leak to others" do
    sign_in @owner
    get root_path(view: "decision")
    assert_equal "decision", @owner.reload.dashboard_view
    assert_equal "overview", @member.reload.dashboard_view

    get root_path
    assert_select "h1", text: I18n.t("investment_decision_center.title")

    get root_path(view: "overview")
    assert_equal "overview", @owner.reload.dashboard_view
  end

  test "a hover prefetch does not change the saved view" do
    sign_in @owner

    get root_path(view: "decision"), headers: { "Sec-Purpose" => "prefetch" }

    assert_response :success
    assert_equal "overview", @owner.reload.dashboard_view
  end

  test "an unknown view value is ignored" do
    sign_in @owner
    get root_path(view: "<script>")

    assert_response :success
    assert_equal "overview", @owner.reload.dashboard_view
  end
end
