require "test_helper"

class StyledFormBuilderTest < ActionView::TestCase
  setup do
    @builder = StyledFormBuilder.new(:account_statement, nil, self, {})
  end

  test "a labelled file field sits in a form field with its label" do
    field = Nokogiri::HTML.fragment(@builder.file_field(:files, label: "Statement files")).at(".form-field")

    assert field, "expected the file input wrapped in a .form-field"
    assert_equal "account_statement_files", field.at("label.form-field__label")["for"]
    assert_includes field.at("input[type=file]")["class"].split, "file:bg-container-inset"
  end

  # The dropzones pass `hidden` and draw their own target: no wrapper, and
  # their classes merged in rather than replaced.
  test "an unlabelled file field comes back bare and keeps the caller's classes" do
    fragment = Nokogiri::HTML.fragment(@builder.file_field(:files, class: "hidden"))

    assert_nil fragment.at(".form-field")
    assert_includes fragment.at("input[type=file]")["class"].split, "hidden"
  end

  # Every styled form's submit shows this while the request is in flight, so
  # it has to come from the locale rather than a literal English string.
  test "submit shows a localized pending label while submitting" do
    button = Nokogiri::HTML.fragment(@builder.submit("Save")).at("button[type=submit]")

    assert button, "expected a submit button"
    assert_equal I18n.t("helpers.submit.submitting"), button["data-turbo-submits-with"]
    assert_equal "Save", button.text.strip
  end
end
