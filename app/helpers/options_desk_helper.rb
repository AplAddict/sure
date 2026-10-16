# Presentation for the Options Desk page. Formats the approved read model; it
# never calculates and never reads Row#broker_mark as a price.
module OptionsDeskHelper
  EXCLUSION_GROUP_LIMIT = 10
  DELTA_REASONS = %w[too_close_to_expiry no_two_sided_market no_direct_quote].freeze
  OPTION_TYPE_LABELS = { "PUT" => "put", "CALL" => "call" }.freeze

  # One summarised exclusion line: how many of an account's contracts share the same reason set.
  ExclusionSummary = Data.define(:account_id, :account_name, :reasons, :count)

  # A broker-supplied currency code can be anything. Only a known ISO code may reach Money.
  def options_desk_currency_ok?(amount, currency)
    return false if amount.nil? || currency.blank?

    Money::Currency.new(currency)
    true
  rescue ArgumentError
    false
  end

  def options_desk_money(amount, currency, title:)
    return options_desk_unavailable(title) unless options_desk_currency_ok?(amount, currency)

    investment_money(amount, currency, title: title)
  end

  def options_desk_gain(amount, currency, title:)
    return options_desk_unavailable(title) unless options_desk_currency_ok?(amount, currency)

    investment_gain(amount, currency, title: title)
  end

  # Summary-card value: a quiet em dash at headline size with the cause as small secondary text.
  def options_desk_stat_unavailable(cause)
    safe_join([
      tag.span("—", class: "block text-xl font-semibold text-secondary"),
      tag.span(cause, class: "block text-xs font-normal text-secondary")
    ])
  end

  # One row per account, underlying and reason set, capped PER ACCOUNT so no account (or its late-sorting symbols) can be
  # pushed off the page by another account's long chain. Returns [groups, hidden] where each group is
  # [first_exclusion, contract_count] and hidden is [[account_name, hidden_group_count], ...].
  def options_desk_exclusion_groups(exclusions, limit: EXCLUSION_GROUP_LIMIT)
    visible = []
    hidden = []
    exclusions.group_by(&:account_id).each_value do |account_entries|
      groups = account_entries.group_by { |entry| [ entry.underlying, Array(entry.reasons).map(&:to_s).sort ] }
                              .values.map { |entries| [ entries.first, entries.size ] }
      visible.concat(groups.first(limit))
      hidden << [ account_entries.first.account_name, groups.size - limit ] if groups.size > limit
    end
    [ visible, hidden ]
  end

  # Desk-page exclusions: one entry per account and reason set with the number of contracts, so a long chain is a
  # handful of lines rather than hundreds. Accounts never pool (keyed by id), and the biggest reason sets come first.
  # Returns [[account_name, reasons, count], ...]; options_desk_exclusion_rows adds the per-account cap.
  def options_desk_exclusion_summary(exclusions)
    options_desk_exclusion_rows(exclusions, limit: nil).first.map { |row| [ row.account_name, row.reasons, row.count ] }
  end

  # Returns [rows, hidden]: ExclusionSummary rows (capped per account when limit is given) and
  # [[account_name, hidden_group_count], ...] for accounts that had more reason sets than the cap.
  def options_desk_exclusion_rows(exclusions, limit: EXCLUSION_GROUP_LIMIT)
    rows = []
    hidden = []
    exclusions.group_by(&:account_id).each do |account_id, entries|
      summaries = entries.group_by { |entry| Array(entry.reasons).map(&:to_s).sort }
                         .map { |reasons, grouped| ExclusionSummary.new(account_id: account_id, account_name: entries.first.account_name, reasons: reasons.map(&:to_sym), count: grouped.size) }
                         .sort_by.with_index { |summary, index| [ -summary.count, index ] }
      shown = limit ? summaries.first(limit) : summaries
      rows.concat(shown)
      hidden << [ entries.first.account_name, summaries.size - shown.size ] if summaries.size > shown.size
    end
    [ rows, hidden ]
  end

  def options_desk_exclusion_line(summary)
    t("options_reviews.desk.ideas.excluded_summary", count: summary.count, reasons: summary.reasons.map { |reason| options_desk_reason(reason) }.join(", "))
  end

  # "21 current marks - 2 broker - 0 indicative". Counted from the rows' evidence so overlapping summary counters can
  # never make the broker figure wrong.
  def options_desk_mark_breakdown(desk)
    t("options_reviews.desk.summary.mark_breakdown", count: desk.summary.current_mark_count, broker: desk.rows.count { |row| row.evidence_status == :broker },
                                                     indicative: desk.summary.indicative_count)
  end

  # Presentation order only: nearest expiry first, stable for ties, rows without an expiry last.
  def options_desk_group_rows(group)
    group.rows.each_with_index.sort_by { |row, index| [ row.expiration ? 0 : 1, row.expiration || Date.new(9999), index ] }.map(&:first)
  end

  # "NVDA $215 Put" from the row's own structured fields, or nil so the caller falls back to the OCC string alone.
  def options_desk_contract_label(row)
    type = OPTION_TYPE_LABELS[row.option_type.to_s.upcase]
    return if row.underlying.blank? || type.nil? || !row.strike.respond_to?(:finite?) || !row.strike.finite?

    strike = number_with_precision(row.strike, precision: 4, strip_insignificant_zeros: true)
    symbol = options_desk_currency_ok?(row.strike, row.currency) ? Money::Currency.new(row.currency).symbol : ""
    t("options_reviews.desk.contract_label", underlying: row.underlying, strike: "#{symbol}#{strike}", type: t("options_reviews.desk.option_types.#{type}"))
  end

  def options_desk_delta_reason(reason)
    key = DELTA_REASONS.include?(reason.to_s) ? reason.to_s : "unavailable"
    t("options_reviews.desk.delta_reasons.#{key}")
  end

  def options_desk_side_pill(row)
    return unless %i[long short].include?(row.side)

    render DS::Pill.new(label: t("options_reviews.desk.side.#{row.side}"), tone: :neutral, marker: false, size: :sm)
  end

  def options_desk_unavailable(cause)
    tag.span(class: "text-secondary") do
      safe_join([ tag.span("—", class: "mr-1"), cause ], " ")
    end
  end

  def options_desk_mark_cell(row)
    mark = row.mark
    if mark&.value && options_desk_currency_ok?(mark.value, row.currency)
      as_of = mark.as_of ? t("options_reviews.desk.as_of", time: l(mark.as_of, format: :short)) : nil
      tag.span(class: "block text-right") do
        safe_join([
          options_desk_money(mark.value, row.currency, title: t("options_reviews.desk.mark")),
          tag.span(class: "block text-xs text-secondary") do
            safe_join([ options_desk_mark_basis(mark.basis), as_of ].compact, " · ")
          end
        ])
      end
    else
      options_desk_unavailable(options_desk_missing_mark_cause(row))
    end
  end

  def options_desk_pnl_cell(row)
    return options_desk_unavailable(t("options_reviews.desk.causes.missing_currency")) unless options_desk_currency_ok?(0, row.currency)
    return options_desk_gain(row.total_pnl, row.currency, title: t("options_reviews.desk.columns.total_pnl")) unless row.total_pnl.nil?
    return options_desk_unavailable(t("options_reviews.desk.causes.missing_cost_basis")) if row.mark&.aggregatable? && row.entry_basis_total.nil?
    return options_desk_unavailable(t("options_reviews.desk.causes.indicative")) if row.evidence_status == :indicative

    options_desk_unavailable(options_desk_missing_mark_cause(row))
  end

  def options_desk_delta_cell(row)
    value = row.position_delta || row.model_delta&.value
    return tag.span(options_desk_unavailable(options_desk_delta_reason(row.model_delta&.reason)), class: "whitespace-nowrap text-xs") if value.nil?

    tag.span(number_with_precision(value, precision: 4, strip_insignificant_zeros: true), class: "privacy-sensitive tabular-nums")
  end

  def options_desk_evidence_cell(row)
    if row.evidence_status == :stale
      synced = row.broker_synced_at && t("options_reviews.desk.synced_ago", time: time_ago_in_words(row.broker_synced_at))
      return tag.span(class: "block") do
        safe_join([
          tag.span(t("options_reviews.desk.evidence.stale"), class: "block"),
          (synced ? tag.span(synced, class: "block text-xs text-secondary") : nil)
        ].compact)
      end
    end

    # Only the quote time that backs the displayed mark is shown; a rejected or absent quote has no as-of.
    backing = %i[current indicative].include?(row.evidence_status) ? row.mark&.as_of : nil
    as_of = backing && t("options_reviews.desk.as_of", time: l(backing, format: :short))
    tag.span(class: "block") do
      safe_join([
        tag.span(t("options_reviews.desk.evidence.#{row.evidence_status}", default: row.evidence_status.to_s.humanize), class: "block"),
        (as_of ? tag.span(as_of, class: "block text-xs text-secondary") : nil)
      ].compact)
    end
  end

  def options_desk_group_total(group, desk)
    return options_desk_gain(group.total_pnl, group.currency, title: t("options_reviews.desk.group.subtotal")) unless group.total_pnl.nil?
    return options_desk_unavailable(t("options_reviews.desk.unreadable", count: desk.summary.unreadable_source_count)) if desk.summary.unreadable_source_count.positive?
    return options_desk_unavailable(t("options_reviews.desk.causes.mixed_currency")) if group.currency.blank?

    options_desk_unavailable(t("options_reviews.desk.group.unmeasured", count: group.unavailable_count))
  end

  def options_desk_expiry_cell(row, now)
    return options_desk_unavailable(t("options_reviews.desk.causes.missing_expiry")) if row.expiration.nil?

    today = Options::MarketCalendar.market_date(now)
    days = (row.expiration - today).to_i
    tag.span(class: "whitespace-nowrap") do
      parts = [ l(row.expiration), t("options_reviews.show.dte", count: days.abs) ]
      safe_join([
        tag.span(parts.join(" · ")),
        options_desk_expiry_pill(days)
      ].compact, " ")
    end
  end

  def options_desk_flag(flag)
    t("options_reviews.desk.flags.#{flag}", default: flag.to_s.humanize)
  end

  def options_desk_reason(reason)
    t("options_reviews.desk.reasons.#{reason}", default: reason.to_s.humanize)
  end

  def options_desk_source_banner_copy(state)
    t("options_reviews.desk.source.#{state}")
  end

  private
    def options_desk_mark_basis(basis)
      t("options_reviews.desk.basis.#{basis}", default: basis.to_s.humanize)
    end

    def options_desk_missing_mark_cause(row)
      return t("options_reviews.desk.evidence.stale") if row.evidence_status == :stale
      return t("options_reviews.desk.causes.#{row.evidence_reason}") if row.evidence_reason.present?

      t("options_reviews.desk.causes.no_mark")
    end

    def options_desk_expiry_pill(days)
      if days.negative?
        tag.span(data: { testid: "option-expired" }) do
          render DS::Pill.new(label: t("options_reviews.show.expired_ago", count: days.abs), tone: :error, marker: false, size: :sm)
        end
      elsif days <= OptionsDesk::EXPIRING_SOON_DAYS
        tag.span(data: { testid: "option-expiry-soon" }) do
          render DS::Pill.new(label: t("options_reviews.show.expires_in", count: days), tone: :warning, marker: false, size: :sm)
        end
      end
    end
end
