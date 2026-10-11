module Assistant
  Error = Class.new(StandardError)

  REGISTRY = {
    "builtin" => Assistant::Builtin,
    "external" => Assistant::External
  }.freeze

  # Tools for users who opted into preview features in Settings -> Preferences.
  #
  # Statement Vault + provenance tools back the wealth agent-harness workflow
  # documented in docs/llm-guides/wealth-agent-harness.md. GetValuations is the
  # read pair for RecordValuation; GetInsights reads the Insights feed, which is
  # itself preview-gated app-wide.
  #
  # The bills tools back the preview-gated Bills subsystem.
  PREVIEW_FUNCTION_CLASSES = [
    Function::UploadAccountStatement,
    Function::ListAccountStatements,
    Function::GetAccountStatement,
    Function::GetStatementCoverage,
    Function::RecordValuation,
    Function::GetValuations,
    Function::GetInsights,
    # Bills: the whole subsystem is preview-gated, so its tools ride the same
    # per-user flag as the surfaces they operate on. Each tool additionally
    # re-checks the family's recurring feature gate and the user's
    # account-access scope itself.
    Function::GetBills,
    Function::GetBillDetails,
    Function::GetPaycheckPlan,
    Function::GetBillAudit,
    Function::CreateBill,
    Function::UpdateBill,
    Function::RecordBillPayment
  ].freeze

  # Read family-wide stores that cannot be filtered per account. (GetInsights used to be
  # here, but insights are now scoped per user via Insight.visible_to, so it is safe.)
  FAMILY_WIDE_FUNCTION_CLASSES = [
    Function::SearchFamilyFiles
  ].freeze

  MCP_READ_FUNCTION_CLASSES = [
    Function::GetTransactions,
    Function::GetRecurringTransactions,
    Function::GetAccounts,
    Function::GetHoldings,
    Function::GetBalanceSheet,
    Function::GetIncomeStatement,
    Function::GetBudget,
    Function::GetTags,
    Function::GetCategories,
    Function::GetMerchants
  ].freeze

  class << self
    def for_chat(chat)
      implementation_for(chat).for_chat(chat)
    end

    def config_for(chat)
      raise Error, "chat is required" if chat.blank?
      Assistant::Builtin.config_for(chat)
    end

    def available_types
      REGISTRY.keys
    end

    # External MCP clients are intentionally read-only. Keep this registry
    # separate from builtin chat tools so a new write tool cannot become
    # remotely callable merely by being added to the assistant.
    def mcp_read_function_classes(_user = nil)
      MCP_READ_FUNCTION_CLASSES
    end

    # The builtin assistant has a broader, in-app tool surface.
    def function_classes(user = nil)
      classes = [
        Function::GetTransactions,
        Function::GetRecurringTransactions,
        Function::GetAccounts,
        Function::GetHoldings,
        Function::GetBalanceSheet,
        Function::GetIncomeStatement,
        Function::GetBudget,
        Function::ImportBankStatement,
        Function::SearchFamilyFiles,
        Function::CreateGoal,
        Function::GetTags,
        Function::CreateTag,
        Function::UpdateTag,
        Function::GetCategories,
        Function::CreateCategory,
        Function::UpdateCategory,
        Function::GetMerchants,
        Function::UpdateTransaction,
        Function::CreateTransaction,
        Function::DeleteTransaction,
        Function::UpdateBudget,
        Function::ArchiveChatDocument
      ]

      classes += PREVIEW_FUNCTION_CLASSES if user&.preview_features_enabled?

      # These read family-wide stores that cannot be filtered per account, so
      # they are only offered when the family has a single member.
      unless user.nil? || user.family.users.count == 1
        classes -= FAMILY_WIDE_FUNCTION_CLASSES
      end

      classes
    end

    private

      def implementation_for(chat)
        raise Error, "chat is required" if chat.blank?
        type = ENV["ASSISTANT_TYPE"].presence || chat.user&.family&.assistant_type.presence || "builtin"
        REGISTRY.fetch(type) { REGISTRY["builtin"] }
      end
  end
end
