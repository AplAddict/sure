require "test_helper"

class Assistant::Function::DraftDashboardTemplateTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @other = users(:family_member)
    @function = Assistant::Function::DraftDashboardTemplate.new(@user)
  end

  test "is available as a read-only assistant drafting tool" do
    assert_includes Assistant.function_classes(@user), Assistant::Function::DraftDashboardTemplate
    assert_includes Assistant.function_classes(@other), Assistant::Function::DraftDashboardTemplate
    assert_not_includes Assistant.mcp_read_function_classes(@user), Assistant::Function::DraftDashboardTemplate

    definition = @function.to_definition
    assert_equal "draft_dashboard_template", definition[:name]
    assert_equal %w[name rationale widgets], definition.dig(:params_schema, :required)
    assert_equal false, definition.dig(:params_schema, :additionalProperties)
  end

  test "provider schema contains only generic scope and no member portfolio data" do
    schema = @function.params_schema
    serialized = JSON.generate(schema)

    assert_equal schema, Assistant::Function::DraftDashboardTemplate.new(@other).params_schema
    [
      accounts(:investment).id,
      accounts(:investment).name,
      securities(:aapl).id,
      securities(:aapl).ticker,
      holdings(:one).amount.to_s
    ].each do |private_value|
      assert_not_includes serialized, private_value
    end
    assert_not_includes serialized, "account_id"
    assert_not_includes serialized, "security_id"
    assert_includes serialized, "display_intent"
    assert_includes serialized, "scope"
  end

  test "returns a generic scoped draft without writing preferences" do
    before_preferences = @user.preferences.deep_dup

    result = @function.call(
      "name" => "Account Review",
      "rationale" => "Review one account",
      "widgets" => [
        {
          "key" => "portfolio.allocation",
          "settings" => {
            "scope" => "account",
            "grouping" => "security",
            "rows" => 5
          },
          "display_intent" => "Use the account the member selects locally",
          "layout" => { "col_width" => 6, "height" => 4 }
        }
      ]
    )

    assert result[:success], result.inspect
    assert_equal "account", result.dig(:draft, "widgets", 0, "settings", "scope")
    assert_not result.dig(:draft, "widgets", 0, "settings").key?("account_id")
    assert_equal before_preferences, @user.reload.preferences
  end

  test "rejects provider-supplied member identifiers without writing preferences" do
    before_preferences = @user.preferences.deep_dup

    result = @function.call(
      "name" => "Unsafe",
      "rationale" => "Should fail",
      "widgets" => [
        {
          "key" => "portfolio.allocation",
          "settings" => {
            "scope" => "account",
            "account_id" => accounts(:investment).id,
            "grouping" => "security",
            "rows" => 5
          },
          "display_intent" => "Try to select member data remotely",
          "layout" => { "col_width" => 6, "height" => 4 }
        }
      ]
    )

    assert_equal false, result[:success]
    assert_equal "validation_failed", result[:error]
    assert_match(/unknown widget settings/i, result[:message])
    assert_equal before_preferences, @user.reload.preferences
  end
end
