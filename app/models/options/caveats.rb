# Static, honest caveats about what the Black-Scholes model does not capture. Research notes, not advice.
module Options::Caveats
  # Leveraged / inverse ETFs and meme names where borrow cost, dividends and pin risk distort a plain model.
  LEVERAGED_OR_HARD_TO_BORROW = %w[TSLL TSLS NVDL NVDX TQQQ SQQQ SOXL SOXS UVXY GME SPCX AMC].to_set.freeze
  EARLY_ASSIGNMENT_DTE = 7

  module_function

  def for(underlying:, itm:, dte:)
    caveats = []
    if LEVERAGED_OR_HARD_TO_BORROW.include?(underlying.to_s.strip.upcase)
      caveats << :leveraged_or_hard_to_borrow
      caveats << :borrow_dividends_not_modeled
    end
    caveats << :early_assignment_not_modeled if itm == true && dte.is_a?(Numeric) && dte <= EARLY_ASSIGNMENT_DTE
    caveats
  end
end
