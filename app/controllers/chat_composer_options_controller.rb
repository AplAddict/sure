class ChatComposerOptionsController < ApplicationController
  MAX_PER_KIND = 200

  before_action :ensure_ai_enabled

  # Names the signed-in user may @mention in the composer. Accounts and merchants are
  # scoped to the accounts this user can access; nothing is read from other members.
  def show
    user = Current.user

    accounts = user.accessible_accounts.visible.alphabetically.limit(MAX_PER_KIND).pluck(:name)
    categories = user.family.categories.alphabetically.limit(MAX_PER_KIND).pluck(:name)
    merchants = user.family.available_merchants_for(user).alphabetically.limit(MAX_PER_KIND).pluck(:name)

    render json: { accounts: accounts.uniq, categories: categories.uniq, merchants: merchants.uniq }
  end

  private
    def ensure_ai_enabled
      head :forbidden unless Current.user&.ai_enabled?
    end
end
