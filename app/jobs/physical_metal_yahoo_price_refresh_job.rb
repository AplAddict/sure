class PhysicalMetalYahooPriceRefreshJob < ApplicationJob
  queue_as :scheduled
  sidekiq_options lock: :until_executed, on_conflict: :log

  def perform
    PhysicalMetal.where(auto_price_enabled: true).find_each do |metal|
      refresh(metal)
    rescue => e
      Rails.logger.warn("[PhysicalMetalYahooPriceRefresh] physical_metal_id=#{metal.id} error=#{e.class}")
    end
  end

  private
    def refresh(metal)
      response = Provider::YahooFinance.new.fetch_security_price(
        symbol: metal.yahoo_price_symbol,
        date: Date.current
      )
      raise "Yahoo Finance price unavailable" unless response.success?

      price = response.data
      raise "Yahoo Finance returned an invalid price" unless price&.price.to_d.positive?

      metal.account.with_lock do
        metal.update!(
          manual_price_per_troy_ounce: price.price,
          valuation_source: "Yahoo Finance (#{metal.yahoo_price_symbol})",
          valuation_date: price.date || Date.current,
          price_symbol: metal.yahoo_price_symbol
        )
        Account::ReconciliationManager.new(metal.account).reconcile_balance(
          balance: metal.manual_valuation_total,
          date: metal.valuation_date
        ).tap { |result| raise "Could not reconcile physical metal balance" unless result.success? }
        metal.account.update!(balance: metal.manual_valuation_total, cash_balance: 0)
      end
    end
end
