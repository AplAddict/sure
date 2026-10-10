class PhysicalMetal < ApplicationRecord
  include Accountable

  enum :metal_type, { gold: "gold", silver: "silver" }, validate: true
  enum :valuation_state, { unpriced: "unpriced", manually_valued: "manually_valued" }, validate: true

  validates :troy_ounces, numericality: { greater_than: 0 }
  validates :storage_label, presence: true, length: { maximum: 120 }
  validates :cost_basis, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :manual_price_per_troy_ounce, numericality: { greater_than: 0 }, allow_nil: true
  validates :valuation_source, length: { maximum: 120 }, allow_blank: true
  validates :valuation_date, presence: true, if: :any_manual_valuation_detail?
  validates :valuation_source, presence: true, if: :any_manual_valuation_detail?
  validate :storage_label_is_not_address
  validate :manual_valuation_is_complete

  before_validation :derive_valuation_state

  class << self
    def singular_display_name
      "Physical metals"
    end

    def display_name
      "Physical metals"
    end

    def color
      "#D4AF37"
    end

    def icon
      "coins"
    end

    def classification
      "asset"
    end
  end

  def manual_valuation_total
    return nil unless manual_valuation_complete?

    troy_ounces * manual_price_per_troy_ounce
  end

  private
    def any_manual_valuation_detail?
      manual_price_per_troy_ounce.present? || valuation_source.present? || valuation_date.present?
    end

    def storage_label_is_not_address
      return if storage_label.blank?
      return unless storage_label.match?(/\A\d+\s+.+\s+(street|st|avenue|ave|road|rd|boulevard|blvd|drive|dr|lane|ln|court|ct|way)\.?\z/i)

      errors.add(:storage_label, "must be a privacy-safe label, not an address")
    end

    def manual_valuation_complete?
      manual_price_per_troy_ounce.present? && valuation_source.present? && valuation_date.present?
    end

    def manual_valuation_is_complete
      return unless any_manual_valuation_detail?
      return if manual_valuation_complete?

      errors.add(:base, "manual valuation requires a positive price, source, and as-of date")
    end

    def derive_valuation_state
      self.valuation_state = any_manual_valuation_detail? ? "manually_valued" : "unpriced"
    end
end
