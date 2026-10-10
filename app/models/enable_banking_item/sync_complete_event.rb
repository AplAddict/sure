class EnableBankingItem::SyncCompleteEvent
  attr_reader :enable_banking_item

  def initialize(enable_banking_item)
    @enable_banking_item = enable_banking_item
  end

  def broadcast
    enable_banking_item.reload

    # Update UI with latest account data.
    enable_banking_item.accounts.each do |account|
      account.broadcast_sync_complete
    end

    family = enable_banking_item.family
    return unless family

    # Do not stream the connection card or Settings > Providers panel to the
    # family stream. Those render all connection accounts and credential-aware
    # controls, while every family member subscribes to that stream. The toast
    # below makes each browser re-fetch only what it is authorized to view.
    family.broadcast_sync_complete
  end
end
