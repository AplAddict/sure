# Presentation for the Options Desk page. Formats the approved read model; it
# never calculates and never reads Row#broker_mark as a price.
module OptionsDeskHelper
  EXCLUSION_GROUP_LIMIT = 10

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
      tag.span(cause, class: "mt-1 block text-xs font-normal text-secondary")
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

  def options_desk_unavailable(cause)
    tag.span(class: "text-secondary") do
      safe_join([ tag.span("—", class: "mr-1"), cause ])
    end
  end

  def options_desk_day_pnl
    tag.span(class: "whitespace-nowrap text-secondary") do
      safe_join([ tag.span("—", class: "mr-1"), t("options_reviews.desk.day_pnl_unavailable") ])
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
    return options_desk_unavailable(t("options_reviews.desk.causes.delta_unavailable")) if value.nil?

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
