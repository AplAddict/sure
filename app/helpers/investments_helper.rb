# One home for how investment figures are presented, so every investment page
# (holdings, options, income, tax lots, tax-loss harvest) renders unavailable
# data, gains and quantities the same way. It formats; it never calculates.
module InvestmentsHelper
  UNAVAILABLE_TITLE = "Unavailable: the source data needed for this figure is missing".freeze

  # Money that is always privacy-masked, or a dash when the value is unknown.
  # A measured zero renders as zero; only nil is "unavailable".
  def investment_money(amount, currency, title: UNAVAILABLE_TITLE)
    return unavailable_cell(title) if amount.nil?

    tag.span(format_money(Money.new(amount, currency)), class: "privacy-sensitive")
  end

  # Gain/loss with a sign (so colour is never the only signal), tone class and
  # optional percentage. nil amount is unavailable; nil percentage is simply
  # omitted (e.g. zero cost basis).
  def investment_gain(amount, currency, percent: nil, title: UNAVAILABLE_TITLE)
    return unavailable_cell(title) if amount.nil?

    sign = amount.positive? ? "+" : ""
    pct = percent.nil? ? nil : tag.span(" (#{sign}#{number_to_percentage(percent, precision: 1)})", class: "text-xs")
    tag.span(class: gain_tone_class(amount)) do
      safe_join([ tag.span("#{sign}#{format_money(Money.new(amount, currency))}", class: "privacy-sensitive"), pct ].compact)
    end
  end

  # Share/contract quantities are position data, so they are privacy-masked too.
  def investment_quantity(value, precision: 8)
    return unavailable_cell if value.nil?

    tag.span(number_with_precision(value, precision: precision, strip_insignificant_zeros: true), class: "privacy-sensitive")
  end

  def gain_tone_class(amount)
    return "text-primary" if amount.nil?

    amount.positive? ? "text-success" : amount.negative? ? "text-destructive" : "text-primary"
  end

  def unavailable_cell(title = UNAVAILABLE_TITLE)
    tag.span("—", class: "text-secondary", title: title)
  end

  # Status pill for a freshness/availability state, via the design system so the
  # colours are real tokens.
  def freshness_pill(status)
    tone = case status.to_s
    when "current" then :success
    when "stale" then :warning
    else :error
    end
    render DS::Pill.new(label: status.to_s.humanize, tone: tone, marker: false, size: :sm)
  end

  # Label / value / optional hint tile used by the review pages.
  def investment_stat(label, value, hint: nil, tone: "text-primary")
    tag.div(class: "rounded-lg bg-container-inset p-4") do
      safe_join([
        tag.p(label, class: "text-sm text-secondary"),
        tag.p(value, class: "mt-2 text-xl font-semibold #{tone}"),
        (hint ? tag.p(hint, class: "mt-1 text-xs text-secondary") : nil)
      ].compact)
    end
  end
end
