require "test_helper"

class InvestmentInsightsTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    @owner = users(:family_admin)
    @member = users(:family_member)
    @family = @owner.family
    @owner.update!(preferences: (@owner.preferences || {}).merge("preview_features_enabled" => true))
    @member.update!(preferences: (@member.preferences || {}).merge("preview_features_enabled" => true))

    @account = @family.accounts.create!(
      name: "Insight Brokerage", balance: 10_000, cash_balance: 0, currency: "USD", owner: @owner,
      status: "active", accountable: Investment.new(subtype: "brokerage")
    )
    @loser = Security.create!(ticker: "INSLOSS", exchange_mic: "XNAS", name: "Loser Corp")
    @winner = Security.create!(ticker: "INSWIN", exchange_mic: "XNAS", name: "Winner Corp")
    hold(@loser, qty: 10, price: 70, cost_basis: 100)   # 30% loss, $300
    hold(@winner, qty: 100, price: 100, cost_basis: 50) # large weight, gain
  end

  # ---- generators ----

  test "tax loss harvest insight is owned by the member whose accounts produced it" do
    insights = Insight::Generators::TaxLossHarvestGenerator.new(@family, user: @owner).generate

    assert_equal 1, insights.size
    insight = insights.first
    assert_equal @owner.id, insight.user_id
    assert_equal "tax_loss_harvest", insight.insight_type
    assert_equal 1, insight.facts[:count]
    assert_equal "INSLOSS", insight.facts[:largest]
    assert_includes insight.dedup_key, "u#{@owner.id}"
  end

  test "generators produce nothing for a member who cannot access the account" do
    [ Insight::Generators::TaxLossHarvestGenerator, Insight::Generators::WashSaleWindowGenerator,
      Insight::Generators::PositionConcentrationGenerator, Insight::Generators::PositionEventsGenerator,
      Insight::Generators::CostBasisGapGenerator ].each do |generator|
      assert_empty generator.new(@family, user: @member).generate, "#{generator} leaked an account to another member"
    end
  end

  test "dedup keys differ per member so two members never overwrite each other" do
    AccountShare.create!(account: @account, user: @member, permission: "read_only", include_in_finances: true)

    owner_key = Insight::Generators::TaxLossHarvestGenerator.new(@family, user: @owner).generate.first.dedup_key
    member_key = Insight::Generators::TaxLossHarvestGenerator.new(@family, user: @member).generate.first.dedup_key

    assert_not_equal owner_key, member_key
  end

  test "small losses below the threshold produce no harvest insight" do
    Holding.where(account: @account, security: @loser).delete_all
    hold(@loser, qty: 10, price: 98, cost_basis: 100)

    assert_empty Insight::Generators::TaxLossHarvestGenerator.new(@family, user: @owner).generate
  end

  test "unknown cost basis is reported as a gap and never as a harvest candidate" do
    nocb = Security.create!(ticker: "INSNOCB", exchange_mic: "XNAS")
    hold(nocb, qty: 5, price: 10, cost_basis: nil)

    gap = Insight::Generators::CostBasisGapGenerator.new(@family, user: @owner).generate.first
    harvest = Insight::Generators::TaxLossHarvestGenerator.new(@family, user: @owner).generate.first

    assert_equal 1, gap.facts[:count]
    assert_equal "INSNOCB", gap.facts[:tickers]
    assert_equal 1, harvest.facts[:count]
  end

  test "concentration insight reports the weight of a large position" do
    insights = Insight::Generators::PositionConcentrationGenerator.new(@family, user: @owner).generate

    assert_equal [ "INSWIN" ], insights.map { |i| i.facts[:ticker] }
    assert_operator insights.first.facts[:weight], :>=, 25
  end

  test "position events list fresh upcoming earnings and ignore stale or far dates" do
    event = ->(type, date, fresh) { MarketCalendar::EventBuilder::Event.new(event_type: type, ticker: "INSWIN", title: "t", date: date, end_date: date, details: "d", source: "s", freshness: fresh) }
    MarketCalendar::EventBuilder.any_instance.stubs(:events).returns([
      event.call("earnings", Date.current + 2, "current"),
      event.call("ex_dividend", Date.current + 3, "stale"),
      event.call("earnings", Date.current + 30, "current")
    ])

    insight = Insight::Generators::PositionEventsGenerator.new(@family, user: @owner).generate.first

    assert_equal 1, insight.facts[:count]
    assert_equal "medium", insight.priority
  end

  test "wash sale window insight is high priority only when replacement purchases are recorded" do
    window = ->(details) { MarketCalendar::EventBuilder::Event.new(event_type: "wash_sale", ticker: "INSLOSS", title: "t", date: Date.current - 5, end_date: Date.current + 25, details: details, source: "s", freshness: "calculated") }

    MarketCalendar::EventBuilder.any_instance.stubs(:events).returns([ window.call("30-day post-loss-sale window. No replacement purchases are currently recorded inside the window.") ])
    assert_equal "low", Insight::Generators::WashSaleWindowGenerator.new(@family, user: @owner).generate.first.priority

    MarketCalendar::EventBuilder.any_instance.stubs(:events).returns([ window.call("30-day window. 5.0 replacement shares are recorded inside the window.") ])
    assert_equal "high", Insight::Generators::WashSaleWindowGenerator.new(@family, user: @owner).generate.first.priority
  end

  # ---- model / registry ----

  test "a user-scoped insight type without an owner is invalid" do
    insight = @family.insights.new(insight_type: "tax_loss_harvest", priority: "low", title: "t", body: "b", dedup_key: "x")

    assert_not insight.valid?
    assert insight.errors[:user].any?
  end

  test "an insight cannot be owned by a user from another family" do
    stranger = users(:empty)
    insight = @family.insights.new(user: stranger, insight_type: "tax_loss_harvest", priority: "low", title: "t", body: "b", dedup_key: "y")

    assert_not insight.valid?
  end

  test "visible_to returns family-wide rows plus only the member's own" do
    shared = @family.insights.create!(insight_type: "idle_cash", priority: "low", title: "shared", body: "b", dedup_key: "shared:1")
    mine = @family.insights.create!(user: @owner, insight_type: "cost_basis_gap", priority: "low", title: "mine", body: "b", dedup_key: "mine:1")
    theirs = @family.insights.create!(user: @member, insight_type: "cost_basis_gap", priority: "low", title: "theirs", body: "b", dedup_key: "theirs:1")

    owner_ids = Insight.visible_to(@owner).pluck(:id)
    member_ids = Insight.visible_to(@member).pluck(:id)

    assert_includes owner_ids, shared.id
    assert_includes owner_ids, mine.id
    assert_not_includes owner_ids, theirs.id
    assert_includes member_ids, theirs.id
    assert_not_includes member_ids, mine.id
  end

  test "registry runs user generators only for opted-in members and records who ran" do
    @member.update!(preferences: (@member.preferences || {}).merge("preview_features_enabled" => false))

    result = Insight::GeneratorRegistry.new(@family).generate_all

    assert_includes result.eligible_user_ids, @owner.id
    assert_not_includes result.eligible_user_ids, @member.id
    assert result.insights.any? { |i| i.user_id == @owner.id && i.insight_type == "tax_loss_harvest" }
    assert result.insights.none? { |i| i.user_id == @member.id }
  end

  private
    def hold(security, qty:, price:, cost_basis:)
      @account.holdings.create!(
        security: security, date: Date.current, qty: qty, price: price, amount: qty * price, currency: "USD",
        cost_basis: cost_basis, cost_basis_source: (cost_basis ? "provider" : nil)
      )
    end
end
