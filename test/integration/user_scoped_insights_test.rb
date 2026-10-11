require "test_helper"

# End-to-end privacy checks for user-scoped (investment) insights: whatever one
# member's brokerage produces must never reach another member through any
# surface — the feed, the nav badge, live updates, push, the API or the AI tool.
class UserScopedInsightsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    SnaptradeAccount.stubs(:includes).returns([])
    ensure_tailwind_build
    @owner = users(:family_admin)
    @member = users(:family_member)
    @family = @owner.family
    [ @owner, @member ].each { |u| u.update!(preferences: (u.preferences || {}).merge("preview_features_enabled" => true)) }

    @shared = @family.insights.create!(insight_type: "idle_cash", priority: "low", title: "Shared family insight",
                                       body: "Everyone sees this.", dedup_key: "idle_cash:shared:1")
    @mine = @family.insights.create!(user: @owner, insight_type: "tax_loss_harvest", priority: "high",
                                     title: "Owner-only harvest insight", body: "Owner holdings detail.",
                                     dedup_key: "tax_loss_harvest:u#{@owner.id}:1")
    @theirs = @family.insights.create!(user: @member, insight_type: "cost_basis_gap", priority: "low",
                                       title: "Member-only gap insight", body: "Member holdings detail.",
                                       dedup_key: "cost_basis_gap:u#{@member.id}:1")
  end

  test "feed shows family-wide and own insights but never another member's" do
    sign_in @owner
    get insights_path

    assert_response :success
    assert_match "Shared family insight", response.body
    assert_match "Owner-only harvest insight", response.body
    assert_no_match(/Member-only gap insight/, response.body)
  end

  test "the insights page subscribes to the viewer's own stream and never a family insights stream" do
    sign_in @owner
    get insights_path
    owner_streams = css_select("turbo-cable-stream-source").map { |n| n["signed-stream-name"] }

    sign_in @member
    get insights_path
    member_streams = css_select("turbo-cable-stream-source").map { |n| n["signed-stream-name"] }

    owner_stream = Turbo::StreamsChannel.signed_stream_name([ @owner, :insights ])
    member_stream = Turbo::StreamsChannel.signed_stream_name([ @member, :insights ])
    family_insights_stream = Turbo::StreamsChannel.signed_stream_name([ @family, :insights ])

    assert_includes owner_streams, owner_stream
    assert_includes member_streams, member_stream
    assert_not_includes owner_streams, member_stream
    assert_not_includes member_streams, owner_stream
    assert_not_includes owner_streams, family_insights_stream
    assert_not_includes member_streams, family_insights_stream
  end

  test "dashboard feed widget and unread badge are scoped to the viewer" do
    sign_in @member
    get root_path

    assert_response :success
    assert_no_match(/Owner-only harvest insight/, response.body)
  end

  test "badge count only counts rows the viewer can read" do
    owner_before = @owner.visible_insights.active.count
    member_before = @member.visible_insights.active.count

    # The two members differ only by the rows each owns.
    assert_equal @family.insights.active.where(user_id: nil).count + 1, owner_before
    assert_equal @family.insights.active.where(user_id: nil).count + 1, member_before

    @theirs.update!(status: "read")

    assert_equal member_before - 1, @member.visible_insights.active.count
    assert_equal owner_before, @owner.visible_insights.active.count
    assert_not_includes @member.visible_insights.pluck(:id), @mine.id
    assert_not_includes @owner.visible_insights.pluck(:id), @theirs.id
  end

  test "a member cannot acknowledge another member's insight" do
    sign_in @member

    patch acknowledge_insight_url(@mine), as: :turbo_stream

    assert_response :not_found
    assert @mine.reload.active?
  end

  test "visiting the feed marks only the viewer's visible insights read" do
    sign_in @member
    get insights_path

    assert @theirs.reload.read?
    assert @shared.reload.read?
    assert @mine.reload.active?, "another member's insight must not be touched"
  end

  test "the API returns only the caller's visible insights" do
    key = ApiKey.generate_secure_key
    api_key = ApiKey.create!(user: @member, name: "Scoped insights test", key: key, scopes: [ "read" ], source: "mobile")

    get api_v1_insights_url, headers: { "X-Api-Key" => key }

    assert_response :success
    titles = response.parsed_body["insights"].map { |i| i["title"] }
    assert_includes titles, "Shared family insight"
    assert_includes titles, "Member-only gap insight"
    assert_not_includes titles, "Owner-only harvest insight"
    assert api_key.persisted?
  end

  test "the assistant tool returns only the asking member's visible insights" do
    tool = Assistant::Function::GetInsights.new(@member)
    titles = tool.call({ "include_acknowledged" => true })[:insights].map { |i| i[:title] }

    assert_includes titles, "Member-only gap insight"
    assert_not_includes titles, "Owner-only harvest insight"

    owner_titles = Assistant::Function::GetInsights.new(@owner).call({})[:insights].map { |i| i[:title] }
    assert_includes owner_titles, "Owner-only harvest insight"
    assert_not_includes owner_titles, "Member-only gap insight"
  end

  test "push notifications for a user-scoped insight go only to its owner" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Apns::Client.stubs(:configured?).returns(true)
    Apns::Client.stubs(:available?).returns(true)
    owner_sub = push_subscription(@owner, "ab" * 32)
    member_sub = push_subscription(@member, "cd" * 32)

    clear_enqueued_jobs
    DeliverInsightNotificationJob.enqueue_for(@mine)

    ids = enqueued_jobs.select { |j| j["job_class"] == "DeliverInsightNotificationJob" }
                       .map { |j| j["arguments"].first["push_subscription_id"] }
    assert_includes ids, owner_sub.id
    assert_not_includes ids, member_sub.id
  end

  test "a replayed push job for another member's subscription is refused" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Apns::Client.stubs(:configured?).returns(true)
    Apns::Client.stubs(:available?).returns(true)
    member_sub = push_subscription(@member, "ef" * 32)
    Apns::Client.expects(:new).never

    DeliverInsightNotificationJob.perform_now(insight_id: @mine.id, push_subscription_id: member_sub.id)
  end

  test "the job writes user-owned rows and expires them per owner without touching others" do
    stale_owner = @family.insights.create!(user: @owner, insight_type: "tax_loss_harvest", priority: "low", title: "Stale owner",
                                           body: "b", dedup_key: "tax_loss_harvest:u#{@owner.id}:stale")
    stale_member = @family.insights.create!(user: @member, insight_type: "tax_loss_harvest", priority: "low", title: "Stale member",
                                            body: "b", dedup_key: "tax_loss_harvest:u#{@member.id}:stale")

    generated = Insight::Generator::GeneratedInsight.new(
      insight_type: "cost_basis_gap", priority: "low", title: "Fresh owner gap", template_key: "cost_basis_gap",
      facts: { count: 1, tickers: "AAA", more: 0 }, metadata: { count: 1 }, currency: "USD",
      period_start: nil, period_end: nil, dedup_key: "cost_basis_gap:u#{@owner.id}:fresh", user_id: @owner.id
    )
    # Only the OWNER's generators completed; the member was not evaluated.
    result = Insight::GeneratorRegistry::Result.new(
      insights: [ generated ], succeeded_types: [], user_succeeded_types: { @owner.id => %w[tax_loss_harvest cost_basis_gap] },
      eligible_user_ids: [ @owner.id ]
    )
    Insight::GeneratorRegistry.any_instance.stubs(:generate_all).returns(result)

    GenerateInsightsJob.perform_now(family_id: @family.id)

    fresh = @family.insights.find_by(dedup_key: "cost_basis_gap:u#{@owner.id}:fresh")
    assert_equal @owner.id, fresh.user_id
    assert stale_owner.reload.expired?
    assert_not stale_member.reload.expired?, "a member who was not evaluated must keep their rows"
    assert_not @shared.reload.expired?
    assert @mine.reload.expired?, "owner's row absent from this run expires because the owner's generators completed"
  end

  test "the job broadcasts to each member's own stream with only their rows" do
    Insight::GeneratorRegistry.any_instance.stubs(:generate_all).returns(
      Insight::GeneratorRegistry::Result.new(insights: [], succeeded_types: [])
    )
    streamed = {}
    Turbo::StreamsChannel.stubs(:broadcast_replace_to).with do |stream, **options|
      if options[:target] == "insights-list"
        streamed[stream.first.id] = options[:locals][:insights].map(&:title)
      end
      true
    end

    GenerateInsightsJob.perform_now(family_id: @family.id)

    assert_includes streamed[@owner.id], "Owner-only harvest insight"
    assert_not_includes streamed[@owner.id], "Member-only gap insight"
    assert_includes streamed[@member.id], "Member-only gap insight"
    assert_not_includes streamed[@member.id], "Owner-only harvest insight"
  end

  private
    def push_subscription(user, token)
      user.push_subscriptions.create!(token: token, environment: "sandbox", platform: "ios", last_registered_at: Time.current)
    end
end
