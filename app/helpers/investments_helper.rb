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

  # A sortable column header cell. aria-sort is announced from the <th>, not
  # from a link inside it, so it lives on the cell: "ascending"/"descending"
  # for the active column and "none" for every other sortable column. The link
  # flips the active column's direction and starts other columns on their
  # natural direction; the block maps (key, direction) to the path.
  def sortable_header(label, key, sort:, direction:, default_direction: "desc", align: :left, css: nil, link_data: {}, &path)
    active = sort == key
    ascending = direction == "asc"
    next_direction = active ? (ascending ? "desc" : "asc") : default_direction
    arrow = active ? (ascending ? "↑" : "↓") : ""

    tag.th(scope: "col", class: class_names(align == :right ? "text-right" : "text-left", css),
           "aria-sort": active ? (ascending ? "ascending" : "descending") : "none") do
      link_to(path.call(key, next_direction),
              class: class_names("inline-flex items-center gap-1 rounded hover:text-primary focus-ring", "justify-end" => align == :right, "text-primary" => active),
              data: link_data) do
        safe_join([ label, tag.span(arrow, class: "w-3 text-xs", "aria-hidden": true) ])
      end
    end
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
