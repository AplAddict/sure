# Last known market quote for one listed option contract. Public reference data:
# there is no family or user column, and a quote only ever reaches a user by
# being joined (by symbol) to a contract in that user's own accessible accounts.
#
# Every number is the source's own figure or nil. A missing price, IV or open
# interest is never stored as zero, because zero is a real value.
#
# The table is a global reference table (no family column) and must only ever
# be joined to a requesting user's own positions, via .lookup. quote_time /
# session_date say when the quote is as of; fetched_at is bookkeeping only.
class OptionQuote < ApplicationRecord
  TYPES = %w[CALL PUT].freeze
  FRESH_WINDOW = 36.hours

  before_validation { self.contract_symbol = self.class.normalize_symbol(contract_symbol) }

  validates :contract_symbol, :underlying, :expiration, :fetched_at, :source, :currency, presence: true
  validates :contract_symbol, uniqueness: true
  validates :option_type, inclusion: { in: TYPES }
  validates :strike, numericality: { greater_than: 0 }

  # SnapTrade writes OCC symbols padded to six characters ("NVDA  261113P00215000");
  # Yahoo's have no spaces. The unpadded upcased form is the join key.
  def self.normalize_symbol(symbol)
    symbol&.to_s&.gsub(/\s+/, "")&.upcase
  end

  OCC_TAIL = /\A(\d{2})(\d{2})(\d{2})([CP])(\d{8})\z/
  STANDARD_MULTIPLIER = 100
  STANDARD_CONTRACT_SIZE = "REGULAR"

  # Parses an OCC symbol from its LAST 15 characters (YYMMDD, C/P, strike x 1000
  # in 8 digits); the root is everything before, so padded roots, unpadded roots
  # and roots containing digits ("GME1  261113C00031000") all work.
  def self.parse_occ(symbol)
    return nil unless symbol.is_a?(String)

    text = symbol.strip.upcase
    return nil if text.length <= 15

    root = text[0...-15].strip
    match = OCC_TAIL.match(text[-15..])
    return nil if match.nil? || !root.match?(/\A[A-Z0-9]+\z/)

    expiration = Date.new(2000 + match[1].to_i, match[2].to_i, match[3].to_i)
    { root: root, expiration: expiration, option_type: match[4] == "C" ? "CALL" : "PUT", strike: BigDecimal(match[5]) / 1000 }
  rescue Date::Error
    nil
  end

  # The quote for one broker contract, joined on structured fields (never on
  # symbol text). Non-standard deliverables (multiplier other than 100, or a
  # contract size other than REGULAR, including unknown) never match: their
  # prices would not describe the position.
  def self.lookup(underlying:, expiration:, option_type:, strike:, multiplier:)
    return nil if underlying.blank? || expiration.nil? || option_type.blank? || strike.nil?
    return nil unless decimal(multiplier) == STANDARD_MULTIPLIER

    strike = decimal(strike)
    return nil if strike.nil?

    where(underlying: underlying.to_s.upcase, expiration: expiration, option_type: option_type.to_s.upcase, strike: strike,
          contract_size: STANDARD_CONTRACT_SIZE).first
  end

  def self.decimal(value)
    return nil if value.nil?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end
  private_class_method :decimal

  scope :for_contracts, ->(symbols) { where(contract_symbol: Array(symbols).filter_map { |symbol| normalize_symbol(symbol).presence }.uniq) }
  scope :fresh, ->(window = FRESH_WINDOW) { where(fetched_at: window.ago..) }
end
