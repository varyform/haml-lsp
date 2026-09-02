# frozen_string_literal: true

require_relative "test_helper"

class DocumentTest < Minitest::Test
  UTF8 = HamlLsp::PositionEncoding.new(HamlLsp::PositionEncoding::UTF8)
  UTF16 = HamlLsp::PositionEncoding.new(HamlLsp::PositionEncoding::UTF16)

  def test_incremental_insert
    doc = document("%p= foo\n")
    doc.apply_changes([{ range: range(0, 7, 0, 7), text: "_bar" }], version: 2)

    assert_equal "%p= foo_bar\n", doc.source
    assert_equal "  ; foo_bar\n", doc.ruby
    assert_equal 2, doc.version
  end

  def test_incremental_replace_across_lines
    doc = document("- if a\n  = b\n%p\n")
    doc.apply_changes([{ range: range(0, 5, 1, 5), text: "x\n  = y" }], version: 2)

    assert_equal "- if x\n  = y\n%p\n", doc.source
  end

  def test_multiple_changes_apply_in_order
    doc = document("abc\n")
    doc.apply_changes(
      [
        { range: range(0, 0, 0, 1), text: "X" },
        { range: range(0, 3, 0, 3), text: "Y" },
      ],
      version: 2,
    )

    assert_equal "XbcY\n", doc.source
  end

  def test_full_replacement
    doc = document("%p\n")
    doc.apply_changes([{ text: "%div\n" }], version: 2)

    assert_equal "%div\n", doc.source
    assert_equal "    \n", doc.ruby
  end

  def test_utf16_positions_count_surrogate_pairs
    doc = document("%p 🎉x\n", encoding: UTF16)
    # "🎉" is two UTF-16 code units, so "x" is at character 5.
    doc.apply_changes([{ range: range(0, 5, 0, 6), text: "y" }], version: 2)

    assert_equal "%p 🎉y\n", doc.source
  end

  def test_utf8_positions_count_bytes
    doc = document("%p Привіт x\n", encoding: UTF8)
    # "%p " (3) + "Привіт" (12 bytes) + " " (1) => "x" is at byte 16.
    doc.apply_changes([{ range: range(0, 16, 0, 17), text: "y" }], version: 2)

    assert_equal "%p Привіт y\n", doc.source
  end

  def test_out_of_range_positions_are_clamped
    doc = document("%p\n")
    doc.apply_changes([{ range: range(5, 0, 9, 9), text: "%hr" }], version: 2)

    assert_equal "%p\n%hr", doc.source
  end


  def test_ruby_is_regenerated_after_changes
    doc = document("= a\n")
    assert_equal "  a\n", doc.ruby

    doc.apply_changes([{ range: range(0, 2, 0, 3), text: "bb" }], version: 2)
    assert_equal "  bb\n", doc.ruby
  end

  private

  def document(source, encoding: UTF16)
    HamlLsp::Document.new(uri: "file:///app/views/x.html.haml", source: source, version: 1, encoding: encoding)
  end

  def range(start_line, start_char, end_line, end_char)
    {
      start: { line: start_line, character: start_char },
      end: { line: end_line, character: end_char },
    }
  end
end
