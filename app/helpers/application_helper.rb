module ApplicationHelper
  include Pagy::Frontend

  def product_name
    Rails.configuration.x.product_name
  end

  def brand_name
    Rails.configuration.x.brand_name
  end

  def styled_form_with(**options, &block)
    options[:builder] = StyledFormBuilder
    form_with(**options, &block)
  end

  # Locale-aware ordinal label for integers.
  # English falls through to Ruby's ordinalize ("1st"); Catalan returns "1r"/"2n"/...
  def localized_ordinal(number)
    case I18n.locale
    when :ca
      n = number.to_i
      suffix = case n
      when 1, 3 then "r"
      when 2 then "n"
      when 4 then "t"
      else "è"
      end
      "#{n}#{suffix}"
    else
      number.to_i.ordinalize
    end
  end

  # Financial percentages must distinguish a measured zero from unavailable data.
  def format_optional_percentage(value, precision: 1)
    return "—" if value.nil?

    number_to_percentage(value, precision: precision)
  end

  def icon(key, size: "md", color: "default", custom: false, as_button: false, **opts)
    extra_classes = opts.delete(:class)
    sizes = { xs: "w-3 h-3", sm: "w-4 h-4", md: "w-5 h-5", lg: "w-6 h-6", xl: "w-7 h-7", "2xl": "w-8 h-8" }
    colors = { default: "text-secondary", white: "text-inverse", success: "text-success", warning: "text-warning", destructive: "text-destructive", info: "text-info", current: "text-current" }

    icon_classes = class_names(
      "shrink-0",
      sizes[size.to_sym],
      colors[color.to_sym],
      extra_classes
    )

    resolved_key = normalize_icon_key(key)

    if custom
      inline_svg_tag("#{resolved_key}.svg", class: icon_classes, **opts)
    elsif as_button
      render DS::Button.new(variant: "icon", class: extra_classes, icon: resolved_key, size: size, type: "button", **opts)
    else
      safe_lucide_icon(resolved_key, class: icon_classes, **opts)
    end
  end

  # Convert alpha (0-1) to 8-digit hex (00-FF)
  def hex_with_alpha(hex, alpha)
    alpha_hex = (alpha * 255).round.to_s(16).rjust(2, "0")
    "#{hex}#{alpha_hex}"
  end

  def title(page_title)
    content_for(:title) { page_title }
  end

  def header_title(page_title)
    content_for(:header_title) { page_title }
  end

  def header_description(page_description)
    content_for(:header_description) { page_description }
  end

  def page_active?(path)
    current_page?(path) || (request.path.start_with?(path) && path != "/")
  end

  # The phone bottom bar shows at most this many destinations and always keeps
  # the last slot for "More" when anything is left over, so the bar never grows
  # past five equal targets.
  MOBILE_PRIMARY_NAV_LIMIT = 4

  # Splits the shared nav-item list into the phone bottom bar's primary
  # destinations (flagged `mobile_primary: true`, capped at the limit) and the
  # overflow that lives behind "More". A list that already fits the limit has no
  # overflow, so intro mode and tiny navs never show an empty "More".
  def mobile_nav_groups(items)
    return [ items.first(MOBILE_PRIMARY_NAV_LIMIT), items.drop(MOBILE_PRIMARY_NAV_LIMIT) ] if items.size <= MOBILE_PRIMARY_NAV_LIMIT

    preferred = items.select { |item| item[:mobile_primary] }
    primary = (preferred + items.reject { |item| item[:mobile_primary] }).first(MOBILE_PRIMARY_NAV_LIMIT)
    primary_ids = primary.map(&:object_id).to_set
    [ primary, items.reject { |item| primary_ids.include?(item.object_id) } ]
  end

  # Wraps a nav-item hash so a single call performs both halves of a
  # preview-gated entry: returns `nil` for users without the flag (so the
  # entry never reaches the rendered nav), and stamps `preview: true` on
  # the hash for users with the flag (so the partial paints the violet
  # dot on the icon). Use inside an `Array#compact` nav-items list.
  def preview_gated_nav_item(item)
    return nil unless preview_features_enabled?
    item.merge(preview: true)
  end

  # Bills is only meaningful while recurring detection is on, since a family that has
  # turned it off has nothing to list. Returns nil so the entry drops out of the
  # `Array#compact` nav list entirely rather than leading to an empty page. The
  # subsystem also ships as a preview feature, so the entry is preview-gated on
  # top: hidden without the flag, violet-dotted with it.
  def bills_nav_item
    return nil if Current.family.nil? || Current.family.recurring_transactions_disabled?

    preview_gated_nav_item(
      {
        name: t("layouts.application.nav.bills"),
        path: bills_path,
        icon: "calendar",
        icon_custom: false,
        active: page_active?(bills_path)
      }
    )
  end

  # Investments is a first-class destination in the main navigation. Its target
  # is the `investments_overview` named route (GET /investments) once that route
  # exists; until then it falls back to the legacy homepage lens, /?view=decision,
  # which keeps working either way.
  #
  # Interface note for the routing side: define
  #   get "investments", to: <the Overview action>, as: :investments_overview
  # rendering the same Decision Center page (pages/decision_center) for the
  # member's accessible investment accounts, and keep /?view=decision as a
  # compatibility entry. Nothing in the view layer needs to change when the
  # route lands: this helper picks it up by name.
  #
  # Like the homepage view switch, the entry is only offered to members with an
  # investment account they can access (nil drops it from the compacted nav
  # list); for anyone else the destination would just fall back to Home.
  def investments_nav_item
    return nil unless investments_nav_available?

    path = respond_to?(:investments_overview_path) ? investments_overview_path : root_path(view: "decision")

    {
      name: t("layouts.application.nav.investments"),
      path: path,
      icon: "trending-up",
      icon_custom: false,
      active: investments_nav_active?
    }
  end

  # Every page of the investment workspace lights the Investments entry, and so
  # does the homepage while it shows the Decision Center lens (so Home and
  # Investments are never both current).
  INVESTMENT_WORKSPACE_PATHS = %w[/investments /portfolio /research /market-events /research_watchlist_entries /tax-loss-harvest].freeze

  def investments_nav_active?
    return true if @dashboard_view == "decision" && request.path == root_path

    INVESTMENT_WORKSPACE_PATHS.any? { |prefix| request.path == prefix || request.path.start_with?("#{prefix}/") }
  end

  def investments_nav_available?
    return false unless Current.user

    @investments_nav_available = Current.user.accessible_accounts.where(accountable_type: "Investment").exists? unless defined?(@investments_nav_available)
    @investments_nav_available
  end

  # Budgets and Goals share one nav slot. Preview users get the "Plan" hub
  # entry fronting both (it stays lit while browsing either subpage, since
  # page_active? is a path-prefix match and /budgets · /goals don't share
  # the /plan prefix). Everyone else gets exactly the pre-Plan Budgets
  # entry — Goals was already hidden without the flag, so their nav is
  # unchanged.
  def plan_nav_item
    if preview_features_enabled?
      {
        name: t("layouts.application.nav.plan"),
        path: plan_path,
        icon: "compass",
        icon_custom: false,
        active: page_active?(plan_path) || page_active?(budgets_path) || page_active?(goals_path),
        preview: true
      }
    else
      {
        name: t("layouts.application.nav.budgets"),
        path: budgets_path,
        icon: "map",
        icon_custom: false,
        active: page_active?(budgets_path)
      }
    end
  end

  # Wrapper around I18n.l to support custom date formats
  def format_date(object, format = :default, options = {})
    date = object.to_date

    format_code = options[:format_code] || Current.family&.date_format

    if format_code.present?
      date.strftime(format_code)
    else
      I18n.l(date, format: format, **options)
    end
  end


  def family_moniker
    Current.family&.moniker_label || I18n.t("shared.family_moniker.singular")
  end

  def family_moniker_downcase
    family_moniker.downcase
  end

  def family_moniker_plural
    Current.family&.moniker_label_plural || I18n.t("shared.family_moniker.plural")
  end

  def family_moniker_plural_downcase
    family_moniker_plural.downcase
  end

  def format_money(number_or_money, options = {})
    return nil unless number_or_money

    Money.new(number_or_money).format(options)
  end

  def totals_by_currency(collection:, money_method:, separator: " | ", negate: false)
    collection.group_by(&:currency)
              .transform_values { |item| calculate_total(item, money_method, negate) }
              .map { |_currency, money| format_money(money) }
              .join(separator)
  end

  def currency_picker_options_for_family(family = Current.family, extra: [])
    return Money::Currency.as_options.map(&:iso_code) unless family

    family.enabled_currency_codes(extra:)
  end

  def currency_label(currency_or_code)
    currency = currency_or_code.is_a?(Money::Currency) ? currency_or_code : Money::Currency.new(currency_or_code)
    "#{currency.name} (#{currency.iso_code})"
  end

  def show_super_admin_bar?
    if params[:admin].present?
      cookies.permanent[:admin] = params[:admin]
    end

    cookies[:admin] == "true"
  end

  def sidekiq_web_available?
    named_routes = Rails.application.routes.named_routes
    named_routes.route_defined?(:sidekiq_web_path) || named_routes.route_defined?(:sidekiq_web_url)
  end

  def assistant_icon
    type = ENV["ASSISTANT_TYPE"].presence || Current.family&.assistant_type.presence || "builtin"
    type == "external" ? "claw" : "ai"
  end

  def default_ai_model
    # Always return a valid model, never nil or empty
    # Delegates to Chat.default_model for consistency
    Chat.default_model
  end

  # Renders Markdown text using Redcarpet
  def markdown(text)
    return "" if text.blank?

    renderer = Redcarpet::Render::HTML.new(
      hard_wrap: true,
      link_attributes: { target: "_blank", rel: "noopener noreferrer" }
    )

    markdown = Redcarpet::Markdown.new(
      renderer,
      autolink: true,
      tables: true,
      fenced_code_blocks: true,
      strikethrough: true,
      superscript: true,
      underline: true,
      highlight: true,
      quote: true,
      footnotes: true
    )

    markdown.render(text).html_safe
  end

  # Generate the callback URL for Enable Banking OAuth (used in views and controller).
  # In production, uses the standard Rails route.
  # In development, uses DEV_WEBHOOKS_URL if set (e.g., ngrok URL).
  def enable_banking_callback_url
    return callback_enable_banking_items_url if Rails.env.production?

    ENV.fetch("DEV_WEBHOOKS_URL", root_url).chomp("/") + "/enable_banking_items/callback"
  end

  # Formats a holding quantity with adaptive precision based on the value size.
  # Shows more decimal places for small quantities (common with crypto).
  #
  # @param qty [Numeric] The quantity to format
  # @param exact [Boolean] Show the full stored precision, without rounding
  # @return [String] Formatted quantity with appropriate precision
  def format_quantity(qty, exact: false)
    return "0" if qty.nil? || qty.zero?

    abs_qty = qty.abs

    precision = if exact
      18    # Preserve the full stored precision for crypto quantities
    elsif abs_qty >= 1
      1     # "10.4"
    elsif abs_qty >= 0.01
      2     # "0.52"
    elsif abs_qty >= 0.0001
      4     # "0.0005"
    else
      8     # "0.00000052"
    end

    # Use strip_insignificant_zeros to avoid trailing zeros like "0.50000000"
    number_with_precision(qty, precision: precision, strip_insignificant_zeros: true)
  end

  private
    def safe_lucide_icon(key, **opts)
      lucide_icon(key, **opts)
    rescue StandardError => e
      Rails.logger.warn("[ApplicationHelper] Falling back to key for unknown icon #{key.inspect}: #{e.message}")
      lucide_icon("key", **opts)
    end

    def normalize_icon_key(key)
      normalized = key.to_s.strip
      return normalized if normalized.blank?

      normalized.downcase
    end

    def calculate_total(item, money_method, negate)
      # Filter out transfer-type transactions from entries
      # Only Entry objects have entryable transactions, Account objects don't
      items = item.reject do |i|
        i.is_a?(Entry) &&
        i.entryable.is_a?(Transaction) &&
        i.entryable.transfer?
      end
      total = items.sum(&money_method)
      negate ? -total : total
    end
end
