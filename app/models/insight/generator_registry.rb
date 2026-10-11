# Runs every insight generator for a family. A failing generator is logged to
# the super-admin debug UI and skipped, so one bad signal never blocks the rest
# of the nightly run. The result records which insight types were produced by
# generators that ran to completion — the job only expires stale insights of
# those types, so a crashing generator can never wipe out its healthy insights.
#
# Two kinds of generator:
#   * GENERATORS run once per family and produce family-wide insights.
#   * USER_GENERATORS run once per opted-in member against that member's own
#     accessible accounts and produce insights owned by that member. They exist
#     because account access is per user: a family-wide row built from one
#     member's brokerage would show it to everyone.
class Insight::GeneratorRegistry
  GENERATORS = [
    Insight::Generators::SpendingAnomalyGenerator,
    Insight::Generators::CashFlowWarningGenerator,
    Insight::Generators::NetWorthMilestoneGenerator,
    Insight::Generators::SubscriptionAuditGenerator,
    Insight::Generators::SavingsRateChangeGenerator,
    Insight::Generators::IdleCashGenerator,
    Insight::Generators::BudgetInsightGenerator,
    Insight::Generators::MaintainedGoalDepletedGenerator
  ].freeze

  USER_GENERATORS = [
    Insight::Generators::TaxLossHarvestGenerator,
    Insight::Generators::WashSaleWindowGenerator,
    Insight::Generators::PositionConcentrationGenerator,
    Insight::Generators::PositionEventsGenerator,
    Insight::Generators::CostBasisGapGenerator
  ].freeze

  # user_succeeded_types: { user_id => [types] } for generators that completed.
  # eligible_user_ids: members evaluated this run; nil means "not evaluated"
  # (user rows are then left alone rather than expired).
  Result = Data.define(:insights, :succeeded_types, :user_succeeded_types, :eligible_user_ids) do
    def initialize(insights:, succeeded_types:, user_succeeded_types: {}, eligible_user_ids: nil)
      super
    end
  end

  def initialize(family)
    @family = family
  end

  def generate_all
    insights = []
    succeeded_types = []
    user_succeeded_types = {}

    GENERATORS.each do |generator_class|
      insights.concat(generator_class.new(family).generate)
      succeeded_types.concat(generator_class.produced_types)
    rescue => e
      log_failure(generator_class, e)
    end

    users = eligible_users
    users.each do |user|
      user_succeeded_types[user.id] = []
      USER_GENERATORS.each do |generator_class|
        insights.concat(generator_class.new(family, user: user).generate)
        user_succeeded_types[user.id].concat(generator_class.produced_types)
      rescue => e
        log_failure(generator_class, e, user: user)
      end
    end

    Result.new(
      insights: insights,
      succeeded_types: succeeded_types,
      user_succeeded_types: user_succeeded_types,
      eligible_user_ids: users.map(&:id)
    )
  end

  private
    attr_reader :family

    # Only members who opted into preview features get user-scoped insights,
    # matching who can see the feed at all.
    def eligible_users
      family.users.with_preview_features.select(&:active?)
    end

    def log_failure(generator_class, error, user: nil)
      DebugLogEntry.capture(
        category: "insights",
        level: "error",
        message: "#{generator_class.name} failed: #{error.class}: #{error.message}",
        source: "Insight::GeneratorRegistry",
        family: family,
        metadata: { generator: generator_class.name, user_id: user&.id, backtrace: error.backtrace&.first(5) }.compact
      )
    end
end
