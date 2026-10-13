# Produces a validated dashboard proposal for preview. It never writes user
# preferences; creation remains a separate CSRF-protected dashboard request.
class Assistant::Function::DraftDashboardTemplate < Assistant::Function
  class << self
    def name = "draft_dashboard_template"

    def description
      <<~INSTRUCTIONS
        Drafts a dashboard page for the user to preview and edit. Return only registered widget types, generic scope intent, and safe display intent.
        Never include account or security identifiers, names, symbols, holdings, or positions. Account/security choices are resolved only
        in the user's local dashboard picker. This tool never creates, changes, or overwrites a page. After showing the rationale and ordered
        widgets, tell the user that they must select any requested scope and explicitly confirm Create Page or Apply to Empty Page in the dashboard.
        Never claim the draft was saved.
      INSTRUCTIONS
    end
  end

  def params_schema
    build_schema(
      required: %w[name rationale widgets],
      properties: {
        name: { type: "string", maxLength: DashboardPageConfigurable::MAX_DASHBOARD_PAGE_NAME },
        rationale: { type: "string", maxLength: Dashboard::TemplateDraft::MAX_RATIONALE_LENGTH },
        widgets: {
          type: "array",
          maxItems: DashboardPageConfigurable::MAX_DASHBOARD_WIDGETS,
          items: { oneOf: available_definitions.map { |definition| widget_schema(definition) } }
        }
      }
    )
  end

  def call(params = {})
    draft = Dashboard::TemplateDraft.new(user: user).validate_intent!(params)
    { success: true, draft: draft, provenance: "ai_draft", persisted: false }
  rescue DashboardPageConfigurable::DashboardPagesValidationError => e
    { success: false, error: "validation_failed", message: e.message, persisted: false }
  end

  private
    def available_definitions
      Dashboard::WidgetRegistry.all
    end

    def widget_schema(definition)
      {
        type: "object",
        additionalProperties: false,
        required: %w[key settings layout display_intent],
        properties: {
          key: { type: "string", const: definition.key },
          settings: settings_schema(definition),
          display_intent: { type: "string", maxLength: Dashboard::TemplateDraft::MAX_DISPLAY_INTENT_LENGTH },
          layout: {
            type: "object",
            additionalProperties: false,
            required: %w[col_width height],
            properties: {
              col_width: { type: "integer", enum: definition.supported_col_widths },
              height: { type: "integer", enum: definition.supported_heights }
            }
          }
        }
      }
    end

    def settings_schema(definition)
      properties = definition.settings.each_with_object({}) do |(_key, setting), result|
        result[setting.key.to_sym] = case setting.type
        when "enum"
          { type: "string", enum: setting.values }
        when "integer"
          { type: "integer", minimum: setting.minimum, maximum: setting.maximum }
        end
      end.compact
      {
        type: "object",
        additionalProperties: false,
        required: properties.keys.map(&:to_s),
        properties: properties
      }
    end
end
