# frozen_string_literal: true

require_relative "test_helper"

class DiagnosticsTest < Minitest::Test
  def test_valid_template_has_no_diagnostics
    assert_empty HamlLsp::Diagnostics.for(document("%p\n  = foo\n- if a\n  %b\n"))
  end

  def test_inconsistent_indentation_is_reported_on_the_offending_line
    diagnostics = HamlLsp::Diagnostics.for(document("%div\n  %p\n %span\n"))

    assert_equal 1, diagnostics.size
    diagnostic = diagnostics.first
    assert_equal 2, diagnostic[:range][:start][:line]
    assert_equal 1, diagnostic[:range][:start][:character]
    assert_equal 6, diagnostic[:range][:end][:character]
    assert_equal HamlLsp::Diagnostics::SEVERITY_ERROR, diagnostic[:severity]
    assert_equal "haml", diagnostic[:source]
    assert_match(/Inconsistent indentation/, diagnostic[:message])
  end

  def test_explicit_end_is_reported
    diagnostics = HamlLsp::Diagnostics.for(document("- if a\n  %p\n- end\n"))

    assert_equal 1, diagnostics.size
    assert_equal 2, diagnostics.first[:range][:start][:line]
    assert_match(/don't need to use "- end"/, diagnostics.first[:message])
  end

  def test_error_without_line_falls_back_to_first_line
    diagnostics = HamlLsp::Diagnostics.for(document("%div{\n"))

    assert_equal 1, diagnostics.size
    assert_equal 0, diagnostics.first[:range][:start][:line]
    assert_match(/Unbalanced brackets/, diagnostics.first[:message])
  end

  def test_fixture_is_clean
    haml = File.read(File.expand_path("fixtures/show.html.haml", __dir__))
    assert_empty HamlLsp::Diagnostics.for(document(haml))
  end

  private

  def document(source)
    HamlLsp::Document.new(uri: "file:///x.haml", source: source, version: 1)
  end
end
