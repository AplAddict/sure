class ChatComposerOptionsController < ApplicationController
  MAX_PER_KIND = 200

  # Account types shown as their own sections in the @ menu, in display order.
  ACCOUNT_GROUPS = {
    "depository" => %w[Depository],
    "credit_card" => %w[CreditCard],
    "loan" => %w[Loan],
    "investment" => %w[Investment],
    "crypto" => %w[Crypto],
    "property" => %w[Property],
    "vehicle" => %w[Vehicle],
    "other" => %w[OtherAsset OtherLiability PhysicalMetal]
  }.freeze

  before_action :ensure_ai_enabled

  # Names the signed-in user may @mention in the composer. Accounts and merchants are
  # scoped to the accounts this user can access; nothing is read from other members.
  def show
    user = Current.user

    scoped = user.accessible_accounts.visible.alphabetically
    accounts = scoped.limit(MAX_PER_KIND).pluck(:name)
    account_groups = ACCOUNT_GROUPS.each_with_object({}) do |(key, types), groups|
      names = scoped.where(accountable_type: types).limit(MAX_PER_KIND).pluck(:name).uniq
      groups[key] = names if names.any?
    end
    categories = user.family.categories.alphabetically.limit(MAX_PER_KIND).pluck(:name)
    merchants = user.family.available_merchants_for(user).alphabetically.limit(MAX_PER_KIND).pluck(:name)

    render json: { accounts: accounts.uniq, account_groups: account_groups, categories: categories.uniq, merchants: merchants.uniq }
  end

  private
    def ensure_ai_enabled
      head :forbidden unless Current.user&.ai_enabled?
    end
end
