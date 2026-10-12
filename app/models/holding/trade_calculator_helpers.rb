# Shared helpers for holding calculators (ForwardCalculator / ReverseCalculator).
# Expects the including class to expose an `account` reader.
module Holding::TradeCalculatorHelpers
  private
    # Converts a trade's price into the account's currency at the trade-date
    # rate, or nil when no exchange rate is available.
    def converted_trade_price(trade, date:)
      Money.new(trade.price, trade.currency)
        .exchange_to(account.currency, date: date, custom_rate: trade.exchange_rate)
        .amount
    rescue Money::ConversionError
      nil
    end
end
