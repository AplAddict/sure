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
  DASHBOARD_WIDGET_INSTANCE_ID = /\Aw_[0-9a-z]{12}\z/
  DASHBOARD_PAGE_PROVENANCE = %w[ai_draft].freeze

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

  def create_dashboard_page!(name, page_id: nil, template_key: nil, template_account_id: nil, draft: nil, provenance: nil)
    unless draft.nil? || draft.is_a?(Hash)
      raise DashboardPagesValidationError, "draft must be an object"
    end

    if page_id.present?
      raise DashboardPagesValidationError, "templates are only available for custom pages" if template_key.present? || !draft.nil?

      return create_system_dashboard_page!(page_id)
    end

    result = nil
    mutate_dashboard_config do |pages, _current|
      page_name = normalize_custom_page_name(name)
      widgets = if !draft.nil?
        raise DashboardPagesValidationError, "invalid dashboard provenance" unless DASHBOARD_PAGE_PROVENANCE.include?(provenance.to_s)

        validated = Dashboard::TemplateDraft.new(user: self).validate!(draft.merge("name" => page_name))
        page_name = validated.fetch("name")
        validated.fetch("widgets").map { |widget| default_dashboard_widget(dashboard_widget_for_write!(widget.fetch("key")), settings: widget.fetch("settings"), layout: widget.fetch("layout")) }
      else
        raise DashboardPagesValidationError, "dashboard provenance requires a draft" if provenance.present?

        template = dashboard_page_template_for_write!(template_key)
        template.widgets.map do |template_widget|
          settings = template_widget.settings.deep_dup
          if template.account_scoped? && template_account_id.present? && settings.fetch("scope", "overall") == "overall"
            definition = dashboard_widget_for_write!(template_widget.key)
            if definition.settings.dig("scope")&.values&.include?("account")
              settings = settings.merge("scope" => "account", "account_id" => template_account_id.to_s)
            end
          end
          default_dashboard_widget(dashboard_widget_for_write!(template_widget.key), settings: settings, layout: template_widget.layout)
        end
      end
      custom = { "id" => next_dashboard_page_id(pages), "name" => page_name, "widgets" => widgets }
      custom["provenance"] = provenance.to_s unless draft.nil?
      pages << custom
      result = custom
      [ pages, custom["id"], custom ]
    end
    result
  end

  def apply_dashboard_draft!(page_id, draft)
    mutate_dashboard_config do |pages, current|
      page = find_custom_dashboard_page!(pages, page_id)
      raise DashboardPagesValidationError, "drafts can only be applied to an empty page" if page.fetch("widgets").any?

      validated = Dashboard::TemplateDraft.new(user: self).validate!(draft)
      page["name"] = validated.fetch("name")
      page["widgets"] = validated.fetch("widgets").map do |widget|
        default_dashboard_widget(
          dashboard_widget_for_write!(widget.fetch("key")),
          settings: widget.fetch("settings"),
          layout: widget.fetch("layout")
        )
      end
      page["provenance"] = "ai_draft"
      [ pages, current, page ]
    end
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
          remaining_page["widgets"].reject! { |widget| Dashboard::WidgetRegistry.fetch(widget["key"]).investment_required }
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

  def add_dashboard_widget!(page_id, widget_key, settings: nil, allow_duplicate: false)
    mutate_dashboard_config do |pages, current|
      page = find_dashboard_page_for_write!(pages, page_id)
      definition = dashboard_widget_for_write!(widget_key)
      normalized_settings = definition.normalize_settings!(settings, user: self)
      duplicate = page["widgets"].any? { |widget| widget["key"] == definition.key && widget["settings"] == normalized_settings }
      if duplicate && !allow_duplicate
        raise DashboardPagesValidationError, "an identical widget already exists on page"
      end

      page["widgets"] << default_dashboard_widget(definition, settings: normalized_settings)
      [ pages, current, page["widgets"].last ]
    end
  end

  def update_dashboard_widget!(page_id, instance_id, collapsed: nil, layout: nil, settings: nil)
    mutate_dashboard_config do |pages, current|
      page = find_dashboard_page_for_write!(pages, page_id)
      widget = page["widgets"].find { |candidate| candidate["id"] == instance_id.to_s }
      raise DashboardPagesValidationError, "widget not found" unless widget

      widget["collapsed"] = collapsed unless collapsed.nil?
      unless layout.nil?
        widget["layout"] = widget.fetch("layout").merge(normalize_dashboard_layout(layout))
      end
      unless settings.nil?
        definition = dashboard_widget_for_write!(widget.fetch("key"))
        widget["settings"] = definition.normalize_settings!(settings, user: self)
      end
      [ pages, current, widget ]
    end
  end

  def remove_dashboard_widget!(page_id, instance_id)
    mutate_dashboard_config do |pages, current|
      page = find_dashboard_page_for_write!(pages, page_id)
      removed = page["widgets"].reject! { |widget| widget["id"] == instance_id.to_s }
      raise DashboardPagesValidationError, "widget not found" unless removed

      [ pages, current, nil ]
    end
  end

  def reorder_dashboard_widgets!(page_id, instance_ids)
    mutate_dashboard_config do |pages, current|
      page = find_dashboard_page_for_write!(pages, page_id)
      ids = Array(instance_ids).map(&:to_s)
      raise DashboardPagesValidationError, "widget order must contain unique instance ids" unless ids.uniq == ids

      by_id = page["widgets"].index_by { |widget| widget["id"] }
      raise DashboardPagesValidationError, "widget order contains an unknown page widget" unless (ids - by_id.keys).empty?

      page["widgets"] = ids.map { |id| by_id.fetch(id) } + page["widgets"].reject { |widget| ids.include?(widget["id"]) }
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
        raise DashboardPagesValidationError, "unknown dashboard page attributes" unless (page.keys - %w[id name widgets provenance]).empty?

        page_id = page["id"].to_s
        normalized = {
          "id" => page_id,
          "name" => page["name"].to_s.strip,
          "widgets" => normalize_dashboard_widgets(page["widgets"], page_id: page_id)
        }
        normalized["provenance"] = page["provenance"].to_s if page["provenance"].present?
        normalized
      end.then { |pages| validate_dashboard_config!(pages, "home") }
    end

    def normalize_dashboard_widgets(raw_widgets, page_id:)
      raise DashboardPagesValidationError, "widgets must be an array" unless raw_widgets.is_a?(Array)

      raw_widgets.each_with_index.map do |raw_widget, index|
        widget = raw_widget.respond_to?(:to_h) ? raw_widget.to_h.stringify_keys : nil
        raise DashboardPagesValidationError, "each widget must be an object" unless widget
        raise DashboardPagesValidationError, "unknown widget attributes" unless (widget.keys - %w[id key collapsed layout settings]).empty?
        unless widget["collapsed"].nil? || [ true, false ].include?(widget["collapsed"])
          raise DashboardPagesValidationError, "collapsed must be boolean"
        end
        definition = Dashboard::WidgetRegistry.find(widget["key"])
        raise DashboardPagesValidationError, "unknown widget #{widget["key"].inspect}" unless definition

        instance_id = widget["id"].presence || legacy_dashboard_widget_id(page_id, definition.key, index)
        unless DASHBOARD_WIDGET_INSTANCE_ID.match?(instance_id.to_s)
          raise DashboardPagesValidationError, "invalid widget instance id"
        end

        layout = widget.key?("layout") ? normalize_dashboard_layout(widget["layout"]) : {}
        requested_width = layout.fetch("col_width", definition.default_col_width)
        requested_height = layout.fetch("height", definition.default_height)
        migrating_alias = widget["key"].to_s != definition.key
        {
          "id" => instance_id.to_s,
          "key" => definition.key,
          "collapsed" => widget["collapsed"] == true,
          "layout" => {
            "col_width" => migrating_alias && !definition.supported_col_widths.include?(requested_width) ? definition.default_col_width : requested_width,
            "height" => migrating_alias && !definition.supported_heights.include?(requested_height) ? definition.default_height : requested_height
          },
          "settings" => definition.normalize_settings!(widget["settings"], user: self)
        }
      end.tap do |widgets|
        ids = widgets.map { |widget| widget["id"] }
        raise DashboardPagesValidationError, "widget instance ids must be unique per page" unless ids.uniq == ids
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
        if page["provenance"].present? && !DASHBOARD_PAGE_PROVENANCE.include?(page["provenance"])
          raise DashboardPagesValidationError, "invalid dashboard provenance"
        end

        widgets = page["widgets"]
        raise DashboardPagesValidationError, "widgets must be an array" unless widgets.is_a?(Array)
        raise DashboardPagesValidationError, "a page supports at most #{MAX_DASHBOARD_WIDGETS} widgets" if widgets.size > MAX_DASHBOARD_WIDGETS
        instance_ids = widgets.map { |widget| widget["id"] }
        raise DashboardPagesValidationError, "widget instance ids must be unique per page" unless instance_ids.uniq == instance_ids
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
      raise DashboardPagesValidationError, "invalid widget instance id" unless DASHBOARD_WIDGET_INSTANCE_ID.match?(widget["id"].to_s)
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
      definition.normalize_settings!(widget["settings"], user: self)
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

      widgets = ordered_keys.each_with_index.map do |key, index|
        definition = Dashboard::WidgetRegistry.fetch(key)
        legacy_key = key.delete_prefix("home.")
        layout = layouts[legacy_key] || {}
        requested_width = layout["col_span"] == "full" ? 12 : definition.default_col_width
        requested_height = { "compact" => 3, "auto" => 4, "tall" => 6 }.fetch(layout["height"], definition.default_height)
        {
          "id" => legacy_dashboard_widget_id("home", key, index),
          "key" => key,
          "collapsed" => collapsed[legacy_key] == true,
          "layout" => {
            "col_width" => definition.supported_col_widths.include?(requested_width) ? requested_width : definition.default_col_width,
            "height" => definition.supported_heights.include?(requested_height) ? requested_height : definition.default_height
          },
          "settings" => definition.default_settings
        }
      end
      { "id" => "home", "name" => "Home", "widgets" => widgets }
    end

    def synthesized_investments_dashboard_page
      widgets = Dashboard::PageTemplateRegistry.fetch("investment_workspaces").widgets.map do |template_widget|
        default_dashboard_widget(Dashboard::WidgetRegistry.fetch(template_widget.key), settings: template_widget.settings, layout: template_widget.layout)
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

    def dashboard_page_template_for_write!(template_key)
      key = template_key.presence || "blank"
      template = Dashboard::PageTemplateRegistry.find(key)
      raise DashboardPagesValidationError, "unknown page template #{template_key.inspect}" unless template
      if template.widgets.size > MAX_DASHBOARD_WIDGETS
        raise DashboardPagesValidationError, "page template has too many widgets"
      end

      template
    end

    def dashboard_widget_for_write!(widget_key)
      definition = Dashboard::WidgetRegistry.find(widget_key)
      raise DashboardPagesValidationError, "unknown widget #{widget_key.inspect}" unless definition
      if definition.investment_required && !investment_dashboard_access?
        raise DashboardPagesValidationError, "investment widget is unavailable"
      end

      definition
    end

    def default_dashboard_widget(definition, settings: nil, layout: nil)
      requested_layout = (layout || {}).stringify_keys
      {
        "id" => next_dashboard_widget_id,
        "key" => definition.key,
        "collapsed" => false,
        "layout" => {
          "col_width" => requested_layout.fetch("col_width", definition.default_col_width),
          "height" => requested_layout.fetch("height", definition.default_height)
        },
        "settings" => definition.normalize_settings!(settings, user: self)
      }
    end

    def next_dashboard_widget_id
      "w_#{12.times.map { SecureRandom.random_number(36).to_s(36) }.join}"
    end

    def legacy_dashboard_widget_id(page_id, key, index)
      suffix = Digest::SHA256.hexdigest([ id, page_id, key, index ].join(":"))[0, 12]
      "w_#{suffix}"
    end
end
