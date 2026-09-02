# frozen_string_literal: true

require_relative "test_helper"

class HamlCompletionTest < Minitest::Test
  def test_tag_names_after_percent
    result = complete("  %di", 0, 5)
    labels = result[:items].map { |i| i[:label] }

    assert_includes labels, "div"
    assert_includes labels, "dialog"
    assert_includes labels, "p" # the editor filters; we return the full list

    div = result[:items].find { |i| i[:label] == "div" }
    assert_equal HamlLsp::HamlCompletion::KIND_KEYWORD, div[:kind]
    assert_equal "HTML tag", div[:detail]
    assert_equal({ start: { line: 0, character: 3 }, end: { line: 0, character: 5 } }, div[:textEdit][:range])
    assert_equal "div", div[:textEdit][:newText]
    assert_equal({ hamlLsp: true }, div[:data])
  end

  def test_bare_percent
    result = complete("%", 0, 1)
    assert_equal HamlLsp::HamlCompletion::HTML_TAGS.size, result[:items].size
    # Only the (empty) name after `%` is replaced, never the sigil itself.
    assert_equal({ start: { line: 0, character: 1 }, end: { line: 0, character: 1 } },
                 result[:items].first[:textEdit][:range])
  end

  def test_filters_after_colon
    result = complete("  :ja", 0, 5)
    labels = result[:items].map { |i| i[:label] }

    assert_includes labels, "javascript"
    assert_includes labels, "ruby"
    assert_equal "HAML filter", result[:items].first[:detail]
  end

  def test_doctypes
    result = complete("!!! ", 0, 4)
    labels = result[:items].map { |i| i[:label] }

    assert_includes labels, "5"
    assert_includes labels, "Strict"
    assert_equal "<!DOCTYPE html>", result[:items].find { |i| i[:label] == "5" }[:detail]
  end

  def test_nothing_in_plain_text_or_after_tag_content
    assert_empty complete("%p Hello", 0, 8)[:items]
    assert_empty complete("Hello %", 0, 7)[:items]
    assert_empty complete("%div.cl", 0, 7)[:items]
    assert_empty complete("", 0, 0)[:items]
  end

  def test_uses_the_requested_line
    result = complete("%p\n  %sp\n", 1, 5)
    assert_includes result[:items].map { |i| i[:label] }, "span"
    assert_equal 1, result[:items].first[:textEdit][:range][:start][:line]
  end

  private

  def complete(source, line, character)
    document = HamlLsp::Document.new(uri: "file:///x.haml", source: source, version: 1)
    HamlLsp::HamlCompletion.items(document, line, character)
  end
end
