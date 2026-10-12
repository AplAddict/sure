require "test_helper"

class Assistant::Function::ImportBankStatementTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @fn = Assistant::Function::ImportBankStatement.new(@user)
    @openai = Provider::Openai.new("test-key")
  end

  test "model_for falls back to Setting when OPENAI_MODEL env is blank" do
    Setting.stubs(:openai_model).returns("llama3")
    with_env_overrides("OPENAI_MODEL" => "") do
      assert_equal "llama3", @fn.send(:model_for, @openai)
    end
  end

  test "model_for prefers OPENAI_MODEL env when set" do
    Setting.stubs(:openai_model).returns("llama3")
    with_env_overrides("OPENAI_MODEL" => "gpt-4o") do
      assert_equal "gpt-4o", @fn.send(:model_for, @openai)
    end
  end

  test "model_for leaves non-OpenAI providers to their own default" do
    with_env_overrides("OPENAI_MODEL" => "gpt-4o") do
      assert_nil @fn.send(:model_for, Provider::Anthropic.new("test-key"))
    end
  end

  test "a PDF import linked to an account the user cannot access is not readable" do
    family = @user.family
    private_account = family.accounts.create!(name: "Someone Else Private", balance: 100, currency: family.currency, owner: users(:family_member),
                                              status: "active", accountable: Depository.new)
    destination = family.accounts.create!(name: "My Checking", balance: 100, currency: family.currency, owner: @user, status: "active", accountable: Depository.new)
    pdf_import = PdfImport.create!(family: family, account: private_account, document_type: "bank_statement")
    Provider::Registry.expects(:preferred_llm_provider).never

    result = @fn.call("pdf_import_id" => pdf_import.id, "account_id" => destination.id)

    assert_equal false, result[:success]
    assert_equal "PDF import not found", result[:error]
  end

  test "a PDF import linked to an account the user can access is still found" do
    family = @user.family
    mine = family.accounts.create!(name: "My Statement Account", balance: 100, currency: family.currency, owner: @user, status: "active", accountable: Depository.new)
    pdf_import = PdfImport.create!(family: family, account: mine, document_type: "bank_statement")

    result = @fn.call("pdf_import_id" => pdf_import.id)

    assert_equal "account_required", result[:error]
  end
end
