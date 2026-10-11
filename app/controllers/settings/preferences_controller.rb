class Settings::PreferencesController < ApplicationController
  layout "settings"

  def show
    @user = Current.user
    @family_members = Current.family.users.where.not(id: @user.id).where(active: true)
    @budget_shares = @user.budget_shares_given.index_by(&:viewer_id)
  end

  # Writes per-user boolean preferences stored in the JSONB `users.preferences`
  # column. Mirrors Settings::AppearancesController#update so the toggle card on
  # the Preferences page can submit directly without going through the broader
  # UsersController#update flow (which expects a full user form payload).
  def update
    @user = Current.user
    user_params = params.permit(user: [ :preview_features_enabled ]).fetch(:user, {})
    family_params = params.permit(family: [ :include_pending_transactions_in_balances ]).fetch(:family, {})

    if family_params.key?(:include_pending_transactions_in_balances) && !@user.admin?
      return redirect_to settings_preferences_path, alert: "Only an administrator can change family balance settings."
    end

    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      if user_params.key?(:preview_features_enabled)
        updated_prefs["preview_features_enabled"] =
          ActiveModel::Type::Boolean.new.cast(user_params[:preview_features_enabled])
      end
      @user.update!(preferences: updated_prefs)
      Current.family.update!(family_params) if family_params.key?(:include_pending_transactions_in_balances)
    end
    redirect_to settings_preferences_path
  end
end
