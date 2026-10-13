module DashboardPageConfigurable
  extend ActiveSupport::Concern

  MAX_DASHBOARD_PAGES = 8
  MAX_DASHBOARD_WIDGETS = 24
  MAX_DASHBOARD_PAGE_NAME = 40
  MAX_DASHBOARD_PREFERENCES_BYTES = 16.kilobytes
  SYSTEM_DASHBOARD_PAGES = { "home" => "Home", "investments" => "Investments" }.freeze
  CUSTOM_DASHBOARD_PAGE_ID = /\Ap_[0-9a-z]{8}\z/
  DASHBOARD_PAGE_ALIASES = { "overview" => "home", "decision" => "investments" }.freeze
  DASHBOARD_LAYOUT_KEYS = %w[col_width height].freeze

  class DashboardPagesValidationError < StandardError; end

  def dashboard_pages
    pages = stored_dashboard_pages || synthesized_dashboard_pages
    filter_inaccessible_dashboard_content(pages)
  rescue DashboardPagesValidationError
    filter_inaccessible_dashboard_content(synthesized_dashboard_pages)
  end

  def dashboard_current_page
    requested = preferences&.[]("dashboard_current_page").presence || preferences&.[]("dashboard_view")
    resolve_dashboard_page_id(requested)
  end

  def resolve_dashboard_page_id(requested)
    candidate = DASHBOARD_PAGE_ALIASES.fetch(requested.to_s, requested.to_s)
    dashboard_pages.any? { |page| page["id"] == candidate } ? candidate : "home"
  end

  def replace_dashboard_pages!(pages, current_page: nil)
    mutate_dashboard_config do |_existing, existing_current|
      normalized = normalize_dashboard_pages(pages)
      [ normalized, current_page.nil? ? existing_current : current_page.to_s, normalized ]
    end
  end

  def create_dashboard_page!(name, page_id: nil)
    return create_system_dashboard_page!(page_id) if page_id.present?

    result = nil
    mutate_dashboard_config do |pages, _current|
      custom = { "id" => next_dashboard_page_id(pages), "name" => normalize_custom_page_name(name), "widgets" => [] }
      pages << custom
      result = custom
      [ pages, custom["id"], custom ]
    end
    result
  end

  def rename_dashboard_page!(page_id, name)
    mutate_dashboard_config do |pages, current|
      page = find_custom_dashboard_page!(pages, page_id)
      page["name"] = normalize_custom_page_name(name)
      [ pages, current, page ]
    end
  end

  def delete_dashboard_page!(page_id)
    mutate_dashboard_config do |pages, current|
      id = page_id.to_s
      raise DashboardPagesValidationError, "Home cannot be deleted" if id == "home"

      page = pages.find { |candidate| candidate["id"] == id }
      raise DashboardPagesValidationError, "dashboard page not found" unless page

      pages.delete(page)
      if id == "investments"
        pages.each do |remaining_page|
          remaining_page["widgets"].reject! { |widget| widget["key"].start_with?("investments.") }
        end
      end
      [ pages, current == page["id"] ? "home" : current, nil ]
    end
  end

  def reorder_dashboard_pages!(page_ids)
    mutate_dashboard_config do |pages, current|
      ids = Array(page_ids).map(&:to_s)
      existing_ids = pages.map { |page| page["id"] }
      raise DashboardPagesValidationError, "page order must contain unique ids" unless ids.uniq == ids
      raise DashboardPagesValidationError, "page order must contain every page id" unless ids.sort == existing_ids.sort
      raise DashboardPagesValidationError, "Home must remain first" unless ids.first == "home"

      by_id = pages.index_by { |page| page["id"] }
      ordered = ids.map { |id| by_id.fetch(id) }
      [ ordered, current, ordered ]
    end
  end

  def select_dashboard_page!(page_id)
    mutate_dashboard_config do |pages, _current|
      id = resolve_page_id_for_write!(pages, page_id)
      [ pages, id, id ]
    end
  end

  def add_dashboard_widget!(page_id, widget_key)
    mutate_dashboard_config do |pages, current|
      page = find_dashboard_page_for_write!(pages, page_id)
      definition = dashboard_widget_for_write!(widget_key)
      if page["widgets"].any? { |widget| widget["key"] == definition.key }
        raise DashboardPagesValidationError, "widget already exists on page"
      end

      page["widgets"] << default_dashboard_widget(definition)
      [ pages, current, page["widgets"].last ]
    end
  end

  def update_dashboard_widget!(page_id, widget_key, collapsed: nil, layout: nil)
    mutate_dashboard_config do |pages, current|
      page = find_dashboard_page_for_write!(pages, page_id)
      widget = page["widgets"].find { |candidate| candidate["key"] == widget_key.to_s }
      raise DashboardPagesValidationError, "widget not found" unless widget

      widget["collapsed"] = collapsed unless collapsed.nil?
      unless layout.nil?
        widget["layout"] = widget.fetch("layout").merge(normalize_dashboard_layout(layout))
      end
      [ pages, current, widget ]
    end
  end

  def remove_dashboard_widget!(page_id, widget_key)
    mutate_dashboard_config do |pages, current|
      page = find_dashboard_page_for_write!(pages, page_id)
      removed = page["widgets"].reject! { |widget| widget["key"] == widget_key.to_s }
      raise DashboardPagesValidationError, "widget not found" unless removed

      [ pages, current, nil ]
    end
  end

  def reorder_dashboard_widgets!(page_id, widget_keys)
    mutate_dashboard_config do |pages, current|
      page = find_dashboard_page_for_write!(pages, page_id)
      keys = Array(widget_keys).map(&:to_s)
      raise DashboardPagesValidationError, "widget order must contain unique keys" unless keys.uniq == keys

      by_key = page["widgets"].index_by { |widget| widget["key"] }
      raise DashboardPagesValidationError, "widget order contains an unknown page widget" unless (keys - by_key.keys).empty?

      page["widgets"] = keys.map { |key| by_key.fetch(key) } + page["widgets"].reject { |widget| keys.include?(widget["key"]) }
      [ pages, current, page ]
    end
  end

  def investment_dashboard_access?
    accessible_accounts.visible.where(accountable_type: %w[Investment Crypto]).exists?
  end

  private
    def mutate_dashboard_config
      result = nil
      transaction do
        lock!
        pages = filter_inaccessible_dashboard_content(stored_dashboard_pages || synthesized_dashboard_pages)
        current = preferences&.[]("dashboard_current_page").presence || resolve_legacy_dashboard_page
        current = "home" unless pages.any? { |page| page["id"] == current }
        pages, current, result = yield(pages.deep_dup, current)
        pages = validate_dashboard_config!(pages, current)

        updated = (preferences || {}).deep_dup
        updated["dashboard_pages"] = pages
        updated["dashboard_current_page"] = current
        update!(preferences: updated)
      end
      result
    end

    def stored_dashboard_pages
      raw = preferences&.[]("dashboard_pages")
      return nil if raw.nil?

      normalize_dashboard_pages(raw)
    end

    def normalize_dashboard_pages(raw_pages)
      raise DashboardPagesValidationError, "dashboard_pages must be an array" unless raw_pages.is_a?(Array)

      raw_pages.map do |raw_page|
        page = raw_page.respond_to?(:to_h) ? raw_page.to_h.stringify_keys : nil
        raise DashboardPagesValidationError, "each dashboard page must be an object" unless page
        raise DashboardPagesValidationError, "unknown dashboard page attributes" unless (page.keys - %w[id name widgets]).empty?

        {
          "id" => page["id"].to_s,
          "name" => page["name"].to_s.strip,
          "widgets" => normalize_dashboard_widgets(page["widgets"])
        }
      end.then { |pages| validate_dashboard_config!(pages, "home") }
    end

    def normalize_dashboard_widgets(raw_widgets)
      raise DashboardPagesValidationError, "widgets must be an array" unless raw_widgets.is_a?(Array)

      raw_widgets.map do |raw_widget|
        widget = raw_widget.respond_to?(:to_h) ? raw_widget.to_h.stringify_keys : nil
        raise DashboardPagesValidationError, "each widget must be an object" unless widget
        raise DashboardPagesValidationError, "unknown widget attributes" unless (widget.keys - %w[key collapsed layout]).empty?
        unless widget["collapsed"].nil? || [ true, false ].include?(widget["collapsed"])
          raise DashboardPagesValidationError, "collapsed must be boolean"
        end
        definition = Dashboard::WidgetRegistry.find(widget["key"])
        raise DashboardPagesValidationError, "unknown widget #{widget["key"].inspect}" unless definition

        layout = widget.key?("layout") ? normalize_dashboard_layout(widget["layout"]) : {}
        {
          "key" => definition.key,
          "collapsed" => widget["collapsed"] == true,
          "layout" => {
            "col_width" => layout.fetch("col_width", definition.default_col_width),
            "height" => layout.fetch("height", definition.default_height)
          }
        }
      end
    end

    def validate_dashboard_config!(pages, current)
      raise DashboardPagesValidationError, "dashboard_pages must be an array" unless pages.is_a?(Array)
      raise DashboardPagesValidationError, "dashboard supports at most #{MAX_DASHBOARD_PAGES} pages" if pages.size > MAX_DASHBOARD_PAGES

      ids = pages.map { |page| page["id"] }
      raise DashboardPagesValidationError, "page ids must be unique" unless ids.uniq == ids
      raise DashboardPagesValidationError, "Home page is required" unless ids.include?("home")
      raise DashboardPagesValidationError, "Home must remain first" unless ids.first == "home"

      pages.each do |page|
        id = page["id"]
        unless SYSTEM_DASHBOARD_PAGES.key?(id) || CUSTOM_DASHBOARD_PAGE_ID.match?(id)
          raise DashboardPagesValidationError, "invalid dashboard page id"
        end
        name = page["name"].to_s.strip
        if SYSTEM_DASHBOARD_PAGES.key?(id)
          page["name"] = SYSTEM_DASHBOARD_PAGES.fetch(id)
        else
          raise DashboardPagesValidationError, "page name is required" if name.blank?
          raise DashboardPagesValidationError, "page name is too long" if name.length > MAX_DASHBOARD_PAGE_NAME
          page["name"] = name
        end

        widgets = page["widgets"]
        raise DashboardPagesValidationError, "widgets must be an array" unless widgets.is_a?(Array)
        raise DashboardPagesValidationError, "a page supports at most #{MAX_DASHBOARD_WIDGETS} widgets" if widgets.size > MAX_DASHBOARD_WIDGETS
        keys = widgets.map { |widget| widget["key"] }
        raise DashboardPagesValidationError, "widget keys must be unique per page" unless keys.uniq == keys
        widgets.each { |widget| validate_dashboard_widget!(widget) }
      end

      raise DashboardPagesValidationError, "current dashboard page does not exist" unless ids.include?(current.to_s)
      if current.to_s == "investments" && !investment_dashboard_access?
        raise DashboardPagesValidationError, "investment dashboard is unavailable"
      end

      payload = { "dashboard_pages" => pages, "dashboard_current_page" => current.to_s }
      if JSON.generate(payload).bytesize > MAX_DASHBOARD_PREFERENCES_BYTES
        raise DashboardPagesValidationError, "dashboard preferences exceed 16KB"
      end

      pages
    end

    def validate_dashboard_widget!(widget)
      definition = Dashboard::WidgetRegistry.find(widget["key"])
      raise DashboardPagesValidationError, "unknown widget #{widget["key"].inspect}" unless definition
      raise DashboardPagesValidationError, "collapsed must be boolean" unless [ true, false ].include?(widget["collapsed"])

      layout = widget["layout"]
      raise DashboardPagesValidationError, "layout must be an object" unless layout.is_a?(Hash) && (layout.keys - DASHBOARD_LAYOUT_KEYS).empty?
      col_width = layout["col_width"]
      height = layout["height"]
      unless col_width.is_a?(Integer) && definition.supported_col_widths.include?(col_width)
        raise DashboardPagesValidationError, "col_width is not supported for #{definition.key}"
      end
      unless height.is_a?(Integer) && definition.supported_heights.include?(height)
        raise DashboardPagesValidationError, "height is not supported for #{definition.key}"
      end
    end

    def normalize_dashboard_layout(raw_layout)
      unless raw_layout.is_a?(Hash)
        raise DashboardPagesValidationError, "layout must be an object"
      end

      layout = raw_layout.stringify_keys
      raise DashboardPagesValidationError, "unknown layout attributes" unless (layout.keys - DASHBOARD_LAYOUT_KEYS).empty?

      layout
    end

    def synthesized_dashboard_pages
      [ synthesized_home_dashboard_page, synthesized_investments_dashboard_page ]
    end

    def synthesized_home_dashboard_page
      definitions = Dashboard::WidgetRegistry.all.select { |definition| definition.key.start_with?("home.") }
      legacy_order = Array(preferences&.[]("section_order")).map { |key| "home.#{key}" }
      ordered_keys = (legacy_order + definitions.map(&:key)).uniq & definitions.map(&:key)
      collapsed = preferences&.[]("collapsed_sections") || {}
      layouts = preferences&.[]("dashboard_section_layout") || {}

      widgets = ordered_keys.map do |key|
        definition = Dashboard::WidgetRegistry.fetch(key)
        legacy_key = key.delete_prefix("home.")
        layout = layouts[legacy_key] || {}
        requested_width = layout["col_span"] == "full" ? 12 : definition.default_col_width
        requested_height = { "compact" => 3, "auto" => 4, "tall" => 6 }.fetch(layout["height"], definition.default_height)
        {
          "key" => key,
          "collapsed" => collapsed[legacy_key] == true,
          "layout" => {
            "col_width" => definition.supported_col_widths.include?(requested_width) ? requested_width : definition.default_col_width,
            "height" => definition.supported_heights.include?(requested_height) ? requested_height : definition.default_height
          }
        }
      end
      { "id" => "home", "name" => "Home", "widgets" => widgets }
    end

    def synthesized_investments_dashboard_page
      aliases = {
        "pulse" => "investments.decision_pulse",
        "actions" => "investments.decision_action",
        "action" => "investments.decision_action",
        "monitor" => "investments.decision_monitor"
      }
      defaults = %w[investments.decision_pulse investments.decision_action investments.decision_monitor]
      saved = Array(preferences&.[]("investments_decision_section_order")).filter_map { |key| aliases[key.to_s] }
      collapsed = preferences&.[]("investments_decision_collapsed_sections") || {}
      collapsed_keys = {
        "investments.decision_pulse" => "pulse",
        "investments.decision_action" => "actions",
        "investments.decision_monitor" => "monitor"
      }
      widgets = (saved + defaults).uniq.map do |key|
        definition = Dashboard::WidgetRegistry.fetch(key)
        {
          "key" => key,
          "collapsed" => collapsed[collapsed_keys.fetch(key)] == true,
          "layout" => { "col_width" => definition.default_col_width, "height" => definition.default_height }
        }
      end
      { "id" => "investments", "name" => "Investments", "widgets" => widgets }
    end

    def filter_inaccessible_dashboard_content(pages)
      return pages.deep_dup if investment_dashboard_access?

      pages.filter_map do |page|
        next if page["id"] == "investments"

        page.deep_dup.tap do |copy|
          copy["widgets"].reject! { |widget| Dashboard::WidgetRegistry.fetch(widget["key"]).investment_required }
        end
      end
    end

    def resolve_legacy_dashboard_page
      DASHBOARD_PAGE_ALIASES.fetch(preferences&.[]("dashboard_view").to_s, "home")
    end

    def create_system_dashboard_page!(page_id)
      id = page_id.to_s
      raise DashboardPagesValidationError, "unsupported system page" unless id == "investments"
      raise DashboardPagesValidationError, "investment dashboard is unavailable" unless investment_dashboard_access?

      result = nil
      mutate_dashboard_config do |pages, _current|
        if pages.any? { |page| page["id"] == id }
          raise DashboardPagesValidationError, "dashboard page already exists"
        end

        page = synthesized_investments_dashboard_page
        pages << page
        result = page
        [ pages, id, page ]
      end
      result
    end

    def next_dashboard_page_id(pages)
      loop do
        suffix = 8.times.map { SecureRandom.random_number(36).to_s(36) }.join
        id = "p_#{suffix}"
        return id unless pages.any? { |page| page["id"] == id }
      end
    end

    def normalize_custom_page_name(name)
      value = name.to_s.strip
      raise DashboardPagesValidationError, "page name is required" if value.blank?
      raise DashboardPagesValidationError, "page name is too long" if value.length > MAX_DASHBOARD_PAGE_NAME

      value
    end

    def find_custom_dashboard_page!(pages, page_id)
      raise DashboardPagesValidationError, "system pages cannot be renamed" if SYSTEM_DASHBOARD_PAGES.key?(page_id.to_s)

      find_dashboard_page_for_write!(pages, page_id)
    end

    def find_dashboard_page_for_write!(pages, page_id)
      page = pages.find { |candidate| candidate["id"] == page_id.to_s }
      raise DashboardPagesValidationError, "dashboard page not found" unless page
      raise DashboardPagesValidationError, "investment dashboard is unavailable" if page["id"] == "investments" && !investment_dashboard_access?

      page
    end

    def resolve_page_id_for_write!(pages, page_id)
      id = DASHBOARD_PAGE_ALIASES.fetch(page_id.to_s, page_id.to_s)
      find_dashboard_page_for_write!(pages, id)["id"]
    end

    def dashboard_widget_for_write!(widget_key)
      definition = Dashboard::WidgetRegistry.find(widget_key)
      raise DashboardPagesValidationError, "unknown widget #{widget_key.inspect}" unless definition
      if definition.investment_required && !investment_dashboard_access?
        raise DashboardPagesValidationError, "investment widget is unavailable"
      end

      definition
    end

    def default_dashboard_widget(definition)
      {
        "key" => definition.key,
        "collapsed" => false,
        "layout" => { "col_width" => definition.default_col_width, "height" => definition.default_height }
      }
    end
end
