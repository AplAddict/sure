require "test_helper"

# Account-level privacy for the assistant: one family member's private accounts must never
# be visible to, or writable by, another member through any assistant tool.
class Assistant::AccountPrivacyTest < ActiveSupport::TestCase
  setup do
    @owner = users(:family_admin)
    @other = users(:family_member)
    assert_equal @owner.family_id, @other.family_id

    @private_account = Account.create!(
      family: @other.family, owner: @other, accountable: Depository.new,
      name: "Zed Private Savings", currency: "USD", balance: 4321, status: "active"
    )
    assert_not_includes @owner.accessible_accounts.pluck(:id), @private_account.id
  end

  test "get_accounts hides another member's unshared account" do
    result = Assistant::Function::GetAccounts.new(@owner).call
    assert_not_includes JSON.generate(result), "Zed Private Savings"
    assert_includes JSON.generate(Assistant::Function::GetAccounts.new(@other).call), "Zed Private Savings"
  end

  test "get_balance_sheet totals exclude another member's unshared account" do
    before = JSON.generate(Assistant::Function::GetBalanceSheet.new(@owner).call)
    assert_not_includes before, "4321"
  end

  test "create_goal never offers or links another member's account" do
    fn = Assistant::Function::CreateGoal.new(@owner)
    result = fn.call("name" => "Trip", "target_amount" => 100, "linked_account_names" => [ "Zed Private Savings" ])
    blob = JSON.generate(result)
    assert_not_includes blob.sub('"Zed Private Savings"', "REQUESTED"), "Zed Private Savings"
    assert_no_difference -> { Goal.count } do
      fn.call("name" => "Trip", "target_amount" => 100, "linked_account_names" => [ "Zed Private Savings" ])
    end
  end

  test "import_bank_statement cannot target another member's account" do
    fn = Assistant::Function::ImportBankStatement.new(@owner)
    result = fn.call("pdf_import_id" => SecureRandom.uuid, "account_id" => @private_account.id)
    assert_not_includes JSON.generate(result), "Zed Private Savings"
  end

  test "write tools cannot touch another member's account" do
    result = Assistant::Function::CreateTransaction.new(@owner).call(
      "account_id" => @private_account.id, "amount" => 10, "date" => Date.current.to_s, "name" => "x", "nature" => "expense"
    )
    assert_equal false, result[:success] if result.is_a?(Hash) && result.key?(:success)
    assert_equal 0, @private_account.entries.count
  end

  test "family-wide stores are withheld from multi-member families" do
    classes = Assistant.function_classes(@owner)
    assert_not_includes classes, Assistant::Function::SearchFamilyFiles
    assert_not_includes classes, Assistant::Function::GetInsights
    @owner.update!(preferences: (@owner.preferences || {}).merge("preview_features_enabled" => true))
    assert_not_includes Assistant.function_classes(@owner.reload), Assistant::Function::GetInsights
  end

  test "family-wide stores stay available to a single-member family" do
    solo = users(:inactive_trial_user)
    assert_equal 1, solo.family.users.count
    assert_includes Assistant.function_classes(solo), Assistant::Function::SearchFamilyFiles
  end

  test "chats are private to their owner" do
    chat = Chat.create!(user: @owner, title: "private")
    assert_not_includes @other.chats.pluck(:id), chat.id
    assert_raises(ActiveRecord::RecordNotFound) { @other.chats.find(chat.id) }
  end
end
