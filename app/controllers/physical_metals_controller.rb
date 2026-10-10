class PhysicalMetalsController < ApplicationController
  include AccountableResource

  permitted_accountable_attributes :id, :metal_type, :troy_ounces, :storage_label, :cost_basis,
                                 :manual_price_per_troy_ounce, :valuation_source, :valuation_date, :auto_price_enabled

  def create
    @account = Current.family.accounts.build(account_params.except(:return_to, :opening_balance_date).merge(owner: Current.user))
    @account.assign_attributes(balance: valuation_total_or_zero, cash_balance: 0)

    Account.transaction do
      @account.save!
      record_manual_valuation! if @account.physical_metal.manually_valued?
      @account.lock_saved_attributes!
    end

    redirect_to safe_return_to(account_params[:return_to]) || @account, notice: "Physical metals account created"
  rescue ActiveRecord::RecordInvalid => e
    @account ||= e.record.try(:account) || Current.family.accounts.build(currency: Current.family.currency, accountable: PhysicalMetal.new)
    @error_message = e.record.errors.full_messages.join(", ").presence || e.message
    set_link_options
    render :new, status: :unprocessable_entity
  end

  def update
    update_params = account_params.except(:return_to, :balance, :opening_balance_date)
    @account.assign_attributes(update_params)
    @account.assign_attributes(balance: valuation_total_or_zero, cash_balance: 0) if @account.physical_metal.manual_valuation_total.nil?

    Account.transaction do
      @account.save!
      record_manual_valuation! if @account.physical_metal.manually_valued?
      @account.lock_saved_attributes!
    end

    redirect_back_or_to account_path(@account), notice: "Physical metals account updated"
  rescue ActiveRecord::RecordInvalid => e
    @error_message = e.record.errors.full_messages.join(", ").presence || e.message
    render :edit, status: :unprocessable_entity
  end

  private
    def valuation_total_or_zero
      @account.physical_metal&.manual_valuation_total || 0
    end

    def record_manual_valuation!
      metal = @account.physical_metal
      result = Account::ReconciliationManager.new(@account).reconcile_balance(
        balance: metal.manual_valuation_total,
        date: metal.valuation_date
      )
      raise ActiveRecord::RecordInvalid.new(@account) unless result.success?

      @account.update!(balance: metal.manual_valuation_total, cash_balance: 0)
    end
end
