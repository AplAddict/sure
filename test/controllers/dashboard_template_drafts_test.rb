require "test_helper"

class DashboardTemplateDraftsTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: {})
    sign_in @user
    @draft = {
      name: "Tax Focus",
      rationale: "Review measured tax evidence without taking financial action.",
      widgets: [
        { key: "tax.lot_coverage", settings: {}, layout: { col_width: 6, height: 4 } },
        { key: "portfolio.allocation", settings: { scope: "overall", account_id: nil, rows: 5, grouping: "asset_class" }, layout: { col_width: 6, height: 4 } }
      ]
    }
  end

  test "preview validates a structured suggestion without writing" do
    original = @user.preferences.deep_dup

    post template_drafts_path, params: { draft: @draft }, as: :json

    assert_response :success
    assert_equal "Tax Focus", response.parsed_body.dig("draft", "name")
    assert_equal %w[tax.lot_coverage portfolio.allocation], response.parsed_body.dig("draft", "widgets").map { |widget| widget.fetch("key") }
    assert_equal original, @user.reload.preferences
  end

  test "invalid and malicious suggestions are rejected without writes" do
    original = @user.preferences.deep_dup
    suggestions = [
      @draft.merge(admin: true),
      @draft.merge(widgets: [ { key: "trades.execute", settings: {}, layout: {} } ]),
      @draft.merge(widgets: [ { key: "portfolio.allocation", settings: { scope: "account", account_id: "not-accessible" }, layout: {} } ]),
      @draft.merge(widgets: [ { key: "portfolio.security_snapshot", settings: { scope: "security", security_id: securities(:msft).id }, layout: {} } ])
    ]

    suggestions.each do |suggestion|
      post template_drafts_path, params: { draft: suggestion }, as: :json
      assert_response :unprocessable_entity
      assert_equal original, @user.reload.preferences
    end
  end

  test "malformed draft payloads are rejected atomically" do
    original = @user.preferences.deep_dup

    [ "not-an-object", [ @draft ] ].each do |draft|
      post pages_path, params: { page: { name: "Malformed", draft: draft, provenance: "ai_draft" } }, as: :json

      assert_response :unprocessable_entity
      assert_equal original, @user.reload.preferences
    end
  end

  test "local picker resolves assistant scope and rejects unresolved or inaccessible selections" do
    intent = {
      name: "Scoped Review",
      rationale: "Review the locally selected account.",
      widgets: [
        {
          key: "portfolio.allocation",
          settings: { scope: "account", rows: 5, grouping: "security" },
          layout: { col_width: 6, height: 4 },
          display_intent: "Show the account the user confirms locally"
        }
      ]
    }
    original = @user.preferences.deep_dup

    [ nil, "not-an-object", [ accounts(:investment).id ] ].each do |selections|
      post template_drafts_path, params: { draft: intent, selections: selections }, as: :json
      assert_response :unprocessable_entity
      assert_equal original, @user.reload.preferences
    end

    post template_drafts_path, params: { draft: intent, selections: { account_id: accounts(:depository).id } }, as: :json
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences

    post template_drafts_path, params: { draft: intent, selections: { account_id: accounts(:investment).id } }, as: :json
    assert_response :success
    assert_equal accounts(:investment).id, response.parsed_body.dig("draft", "widgets", 0, "settings", "account_id")
    assert_not response.parsed_body.dig("draft", "widgets", 0).key?("display_intent")
    assert_equal original, @user.reload.preferences
  end

  test "explicit confirmation creates a page with minimal provenance" do
    post pages_path, params: { page: { name: @draft[:name], draft: @draft, provenance: "ai_draft" } }, as: :json

    assert_response :created
    page = response.parsed_body.fetch("page")
    assert_equal "ai_draft", page.fetch("provenance")
    assert_equal @draft[:name], page.fetch("name")
    assert_not page.key?("rationale")
    assert_equal 2, page.fetch("widgets").size

    original = @user.reload.preferences.deep_dup
    post pages_path, params: { page: { name: "Spoofed", template: "blank", provenance: "ai_draft" } }, as: :json
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences
  end

  test "apply requires an empty custom page and never overwrites populated pages" do
    empty = @user.create_dashboard_page!("Empty")
    patch apply_draft_page_path(empty.fetch("id")), params: { draft: @draft }, as: :json
    assert_response :success
    assert_equal "ai_draft", response.parsed_body.dig("page", "provenance")

    original = @user.reload.preferences.deep_dup
    patch apply_draft_page_path(empty.fetch("id")), params: { draft: @draft.merge(name: "Overwrite") }, as: :json
    assert_response :unprocessable_entity
    assert_equal original, @user.reload.preferences
  end

  test "draft scope is isolated to the signed in member" do
    reset!
    member = users(:family_member)
    member.update!(preferences: {})
    sign_in member
    account = accounts(:investment)
    assert_not member.accessible_accounts.exists?(id: account.id)
    original = member.preferences.deep_dup
    suggestion = @draft.deep_dup
    suggestion[:widgets][1][:settings] = {
      scope: "account", account_id: account.id, rows: 5,
      grouping: "asset_class"
    }

    post template_drafts_path, params: { draft: suggestion }, as: :json

    assert_response :unprocessable_entity
    assert_equal original, member.reload.preferences
  end

  test "assistant tool returns only a non-persisted validated draft" do
    original = @user.preferences.deep_dup
    provider_draft = @draft.deep_dup
    provider_draft[:widgets].each do |widget|
      widget[:display_intent] = "Show this information without selecting member data"
      widget[:settings] = widget[:settings].except(:account_id, :security_id)
    end
    result = Assistant::Function::DraftDashboardTemplate.new(@user).call(provider_draft.deep_stringify_keys)

    assert result.fetch(:success)
    assert_equal false, result.fetch(:persisted)
    assert_equal "ai_draft", result.fetch(:provenance)
    assert_equal original, @user.reload.preferences
    assert_includes Assistant.function_classes(@user), Assistant::Function::DraftDashboardTemplate
  end

  test "preview endpoint requires authentication" do
    reset!

    post template_drafts_path, params: { draft: @draft }, as: :json

    assert_redirected_to new_session_path
  end
end
