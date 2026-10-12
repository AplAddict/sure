class ExchangeRate < ApplicationRecord
  include Provided

  validates :from_currency, :to_currency, :date, :rate, presence: true
  validates :date, uniqueness: { scope: %i[from_currency to_currency] }
  validate :rate_must_convert_amounts, if: -> { rate.present? }

  def self.valid_rate?(value)
    number = value.is_a?(Numeric) ? value : BigDecimal(value.to_s)
    number.finite? && number.positive?
  rescue ArgumentError, TypeError
    false
  end

  private
    def rate_must_convert_amounts
      errors.add(:rate, :greater_than, count: 0) unless self.class.valid_rate?(rate)
    end
end
