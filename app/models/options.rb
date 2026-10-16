# Namespace + shared settings for the pure-Ruby options calculators
# (MarketCalendar, BlackScholes, Mark, DayGain, ModelDelta, Caveats, IdeaScanner).
module Options
  DEFAULT_RISK_FREE_RATE = 0.04
  MAX_RISK_FREE_RATE = 0.2

  # Assumed risk-free rate for model delta. Invalid, negative or >0.2 env values fall back to the default.
  def self.risk_free_rate
    raw = ENV["OPTIONS_RISK_FREE_RATE"].to_s.strip
    return DEFAULT_RISK_FREE_RATE if raw.empty?

    value = Float(raw, exception: false)
    return DEFAULT_RISK_FREE_RATE unless value&.finite? && value >= 0 && value <= MAX_RISK_FREE_RATE

    value
  end
end
