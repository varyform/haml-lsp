# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "haml_lsp"
require "minitest/autorun"
require "prism"

module ExtractorAssertions
  # Every character of the template is either preserved or replaced by
  # placeholders occupying the same number of code units; extra text is only
  # ever appended after the end of a line.
  def assert_position_preserving(haml, ruby, encoding: HamlLsp::PositionEncoding.new)
    haml_lines = haml.split("\n", -1)
    ruby_lines = ruby.split("\n", -1)
    assert_equal haml_lines.size, ruby_lines.size, "line count differs"

    haml_lines.zip(ruby_lines).each_with_index do |(h, r), index|
      r = r.dup
      h.each_char do |char|
        if r.start_with?(char)
          r = r[1..]
        else
          width = encoding.width(char)
          placeholder = r[0, width]
          assert placeholder.match?(/\A[ ;]+\z/) && placeholder.length == width,
                 "line #{index}: #{char.inspect} replaced by #{placeholder.inspect}\n#{h}\n#{ruby_lines[index]}"
          r = r[width..]
        end
      end
    end
  end

  def assert_parses(ruby)
    result = Prism.parse(ruby, partial_script: true)
    assert result.success?, "shadow does not parse:\n#{ruby}\n#{result.errors.map(&:message).join("\n")}"
  end

  def extract(haml, encoding: HamlLsp::PositionEncoding.new)
    ruby = HamlLsp::RubyExtractor.extract(haml, encoding: encoding)
    assert_position_preserving(haml, ruby, encoding: encoding)
    ruby
  end

  # `expected` uses `·` as a visible stand-in for a space.
  def assert_extracts(expected, haml)
    expected = expected.tr("·", " ")
    assert_equal expected, extract(haml)
    assert_parses(expected)
  end
end
