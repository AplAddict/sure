module Dashboard
  # Validates an assistant-suggested dashboard without writing it. The returned
  # hash is the complete preview/save contract; callers must send a separate,
  # authenticated CSRF-protected request to create a page.
  class TemplateDraft
    MAX_RATIONALE_LENGTH = 240
    MAX_DISPLAY_INTENT_LENGTH = 120
    DRAFT_KEYS = %w[name rationale widgets].freeze
    WIDGET_KEYS = %w[key settings layout].freeze
    INTENT_WIDGET_KEYS = %w[key settings layout display_intent].freeze
    SELECTION_KEYS = %w[account_id security_id].freeze

    def initialize(user:)
      @user = user
    end

    def validate!(raw)
      draft = normalize_draft(raw)

      draft.merge("widgets" => draft.fetch("widgets").map { |widget| normalize_widget(widget) })
    end

    # Provider-facing drafts may express only a generic scope and display intent.
    # Member identifiers are supplied later by the local dashboard picker.
    def validate_intent!(raw)
      draft = normalize_draft(raw)

      draft.merge("widgets" => draft.fetch("widgets").map { |widget| normalize_intent_widget(widget) })
    end

    def resolve_intent!(raw, selections:)
      selection = object!(selections, "selections")
      reject_unknown!(selection, SELECTION_KEYS, "selection")
      intent = validate_intent!(raw)
      concrete = intent.merge(
        "widgets" => intent.fetch("widgets").map do |widget|
          settings = widget.fetch("settings").dup
          settings["account_id"] = selection["account_id"] if settings["scope"] == "account"
          settings["security_id"] = selection["security_id"] if settings["scope"] == "security"
          widget.except("display_intent").merge("settings" => settings)
        end
      )
      validate!(concrete)
    end

    private
      attr_reader :user

      def normalize_draft(raw)
        draft = object!(raw, "draft")
        reject_unknown!(draft, DRAFT_KEYS, "draft")

        name = draft["name"].to_s.strip
        raise validation_error("page name is required") if name.blank?
        if name.length > DashboardPageConfigurable::MAX_DASHBOARD_PAGE_NAME
          raise validation_error("page name is too long")
        end

        rationale = draft["rationale"].to_s.strip
        raise validation_error("rationale is too long") if rationale.length > MAX_RATIONALE_LENGTH

        widgets = draft["widgets"]
        raise validation_error("widgets must be an array") unless widgets.is_a?(Array)
        if widgets.size > DashboardPageConfigurable::MAX_DASHBOARD_WIDGETS
          raise validation_error("draft has too many widgets")
        end

        {
          "name" => name,
          "rationale" => rationale,
          "widgets" => widgets
        }
      end

      def normalize_widget(raw)
        widget = object!(raw, "widget")
        reject_unknown!(widget, WIDGET_KEYS, "widget")
        definition = Dashboard::WidgetRegistry.find(widget["key"])
        raise validation_error("unknown widget #{widget['key'].inspect}") unless definition
        if definition.investment_required && !user.investment_dashboard_access?
          raise validation_error("investment widget is unavailable")
        end

        layout = object!(widget.fetch("layout", {}), "layout")
        reject_unknown!(layout, DashboardPageConfigurable::DASHBOARD_LAYOUT_KEYS, "layout")
        normalized_layout = {
          "col_width" => layout.fetch("col_width", definition.default_col_width),
          "height" => layout.fetch("height", definition.default_height)
        }
        unless normalized_layout["col_width"].is_a?(Integer) && definition.supported_col_widths.include?(normalized_layout["col_width"])
          raise validation_error("col_width is not supported for #{definition.key}")
        end
        unless normalized_layout["height"].is_a?(Integer) && definition.supported_heights.include?(normalized_layout["height"])
          raise validation_error("height is not supported for #{definition.key}")
        end

        {
          "key" => definition.key,
          "settings" => definition.normalize_settings!(widget["settings"], user: user),
          "layout" => normalized_layout
        }
      end

      def normalize_intent_widget(raw)
        widget = object!(raw, "widget")
        reject_unknown!(widget, INTENT_WIDGET_KEYS, "widget")
        definition = Dashboard::WidgetRegistry.find(widget["key"])
        raise validation_error("unknown widget #{widget['key'].inspect}") unless definition

        display_intent = widget["display_intent"].to_s.strip
        raise validation_error("display intent is required") if display_intent.blank?
        raise validation_error("display intent is too long") if display_intent.length > MAX_DISPLAY_INTENT_LENGTH

        layout = object!(widget.fetch("layout", {}), "layout")
        reject_unknown!(layout, DashboardPageConfigurable::DASHBOARD_LAYOUT_KEYS, "layout")
        normalized_layout = {
          "col_width" => layout.fetch("col_width", definition.default_col_width),
          "height" => layout.fetch("height", definition.default_height)
        }
        unless normalized_layout["col_width"].is_a?(Integer) && definition.supported_col_widths.include?(normalized_layout["col_width"])
          raise validation_error("col_width is not supported for #{definition.key}")
        end
        unless normalized_layout["height"].is_a?(Integer) && definition.supported_heights.include?(normalized_layout["height"])
          raise validation_error("height is not supported for #{definition.key}")
        end

        {
          "key" => definition.key,
          "settings" => normalize_intent_settings(definition, widget["settings"]),
          "layout" => normalized_layout,
          "display_intent" => display_intent
        }
      end

      def normalize_intent_settings(definition, raw)
        value = raw.nil? ? {} : raw
        raise validation_error("settings must be an object") unless value.is_a?(Hash)

        safe_settings = definition.settings.reject { |_key, setting| setting.type == "identifier" }
        supplied = value.stringify_keys
        unknown = supplied.keys - safe_settings.keys
        raise validation_error("unknown widget settings: #{unknown.join(', ')}") if unknown.any?

        safe_settings.each_with_object({}) do |(key, setting), normalized|
          candidate = supplied.fetch(key, setting.default)
          case setting.type
          when "enum"
            raise validation_error("#{key} is not supported for #{definition.key}") unless candidate.is_a?(String) && setting.values.include?(candidate)
          when "integer"
            unless candidate.is_a?(Integer) && candidate.between?(setting.minimum, setting.maximum)
              raise validation_error("#{key} is not valid for #{definition.key}")
            end
          end
          normalized[key] = candidate
        end
      end

      def object!(raw, label)
        value = raw.respond_to?(:to_unsafe_h) ? raw.to_unsafe_h : raw
        raise validation_error("#{label} must be an object") unless value.is_a?(Hash)

        value.stringify_keys
      end

      def reject_unknown!(object, allowed, label)
        unknown = object.keys - allowed
        raise validation_error("unknown #{label} attributes: #{unknown.join(', ')}") if unknown.any?
      end

      def validation_error(message)
        DashboardPageConfigurable::DashboardPagesValidationError.new(message)
      end
  end
end
