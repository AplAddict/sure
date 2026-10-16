# Coercion helpers shared by the options calculators. Unknown stays nil; a real 0 stays 0.
# Money is BigDecimal; Floats are converted through their shortest string form (no binary noise).
module Options::Values
  module_function

  # Reads `key` from an object or a Hash (symbol or string key). Missing -> nil.
  def read(source, key)
    return nil if source.nil?
    return source.public_send(key) if !source.is_a?(Hash) && source.respond_to?(key)
    return nil unless source.is_a?(Hash)

    source.key?(key) ? source[key] : source[key.to_s]
  end

  def decimal(value)
    case value
    when nil, true, false then nil
    when BigDecimal then value.finite? ? value : nil
    when Integer then BigDecimal(value)
    when Float then value.finite? ? BigDecimal(value.to_s) : nil
    when Rational then BigDecimal(value, 20)
    when String
      parsed = BigDecimal(value.strip, exception: false)
      parsed&.finite? ? parsed : nil
    end
  end

  # Time-like -> ActiveSupport::TimeWithZone in `zone`; anything unparsable -> nil.
  def time(value, zone)
    return nil if value.nil? || !value.respond_to?(:in_time_zone)

    value.in_time_zone(zone)
  rescue ArgumentError, TypeError
    nil
  end

  # New York calendar date of a time-like value; nil when unparsable or nil.
  def market_date_of(value)
    time(value, Options::MarketCalendar::ZONE_NAME)&.to_date
  end
end
