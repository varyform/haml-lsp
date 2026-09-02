# frozen_string_literal: true

require_relative "test_helper"

# Verifies RubyExtractor#ruby_at?, which tells embedded Ruby positions from
# markup. Each case marks Ruby columns with `^` under the HAML line.
class RubyZonesTest < Minitest::Test
  def test_silent_and_output_scripts
    assert_zones <<~'TEXT'
      - if admin?
       ^^^^^^^^^^^
      = link_to "x", path
       ^^^^^^^^^^^^^^^^^^^
      != raw
        ^^^^^
      ~ pre
       ^^^^^
    TEXT
  end

  def test_empty_script_is_still_ruby
    extractor = extractor_for("= \n- \n")
    assert extractor.ruby_at?(0, 2)
    assert extractor.ruby_at?(1, 2)
    refute extractor.ruby_at?(0, 0)
  end

  def test_plain_text_and_tags_are_not_ruby
    assert_zones <<~'TEXT'
      %p Hello there
      \s
      %div.foo#bar
      \s
      Just text
      \s
      !!! 5
      \s
      -# comment #{x}
      \s
    TEXT
  end

  def test_interpolation
    assert_zones <<~'TEXT'
      %p Hi #{user.name} and #{other}!
              ^^^^^^^^^^       ^^^^^^
      == Total: #{count}
                  ^^^^^^
    TEXT
  end

  def test_tag_attributes_and_inline_script
    assert_zones <<~'TEXT'
      %a.btn{ href: url }= label
            ^^^^^^^^^^^^^ ^^^^^^^
      %li[post] text
         ^^^^^^
      %a(href=url title="x") text
              ^^^^      ^^^
      %a(href=)
              ^
      %p= foo
         ^^^^^
    TEXT
  end

  def test_multiline_attribute_hash
    assert_zones <<~'TEXT'
      %div{ class: a,
          ^^^^^^^^^^^^
            data: b }= body
      ^^^^^^^^^^^^^^^ ^^^^^^
        %p child
      \s
    TEXT
  end

  def test_multiline_html_attributes
    assert_zones <<~'TEXT'
      %a(href=@url
              ^^^^^
             title='x')= text
                   ^^^  ^^^^^^
    TEXT
  end

  def test_multiline_scripts
    assert_zones <<~'TEXT'
      = foo(a, |
       ^^^^^^^^^^
            b) |
      ^^^^^^^^^^^^
      = bar(1,
       ^^^^^^^^
            2)
      ^^^^^^^^^^
      %p
      \s
    TEXT
  end

  def test_filters
    assert_zones <<~'TEXT'
      :ruby
      \s
        x = 1
      ^^^^^^^^
      :javascript
      \s
        alert("#{msg}");
                 ^^^^
    TEXT
  end

  def test_widths_follow_the_encoding
    utf16 = HamlLsp::PositionEncoding.new(HamlLsp::PositionEncoding::UTF16)
    extractor = HamlLsp::RubyExtractor.new("%p 🎉 \#{name}\n", encoding: utf16).tap(&:extract)

    # "%p 🎉 " is 3 + 2 + 1 = 6 units, then "#{" => Ruby starts at 8.
    refute extractor.ruby_at?(0, 7)
    assert extractor.ruby_at?(0, 8)
    assert extractor.ruby_at?(0, 12)
    refute extractor.ruby_at?(0, 13)
  end

  private

  def extractor_for(haml)
    HamlLsp::RubyExtractor.new(haml).tap(&:extract)
  end

  # `spec` alternates HAML lines with marker lines (`^` = Ruby, `\s` = a
  # marker line with no Ruby at all).
  def assert_zones(spec)
    lines = spec.split("\n", -1)
    lines.pop if lines.last == ""
    haml_lines = lines.each_slice(2).map(&:first)
    markers = lines.each_slice(2).map(&:last)
    extractor = extractor_for(haml_lines.join("\n") + "\n")

    haml_lines.each_with_index do |haml, line|
      marker = markers[line].sub('\s', "")
      (0..haml.length).each do |col|
        expected = marker[col] == "^"
        actual = extractor.ruby_at?(line, col)
        assert_equal expected, actual, "line #{line} col #{col}: #{haml.inspect}\n#{haml}\n#{marker}"
      end
    end
  end
end
