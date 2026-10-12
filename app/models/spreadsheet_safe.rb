module SpreadsheetSafe
  FORMULA_START = /\A[=+\-@\t\r]/
  GUARDED_FORMULA_START = /\A'(?=[=+\-@\t\r])/

  def self.encode(value)
    return value unless value.is_a?(String)

    value.match?(FORMULA_START) ? "'#{value}" : value
  end

  def self.decode(value)
    return value unless value.is_a?(String)

    value.sub(GUARDED_FORMULA_START, "")
  end
end
