# frozen_string_literal: true

require_relative "test_helper"

class ShadowDiffTest < Minitest::Test
  ENCODING = HamlLsp::PositionEncoding.new

  def test_identical_texts_produce_no_change
    assert_nil HamlLsp::ShadowDiff.change("a\nb\n", "a\nb\n", ENCODING)
  end

  def test_single_line_change_replaces_only_that_line
    change = HamlLsp::ShadowDiff.change("a\nb\nc\n", "a\nB\nc\n", ENCODING)

    assert_equal({ start: { line: 1, character: 0 }, end: { line: 2, character: 0 } }, change[:range])
    assert_equal "B\n", change[:text]
  end

  def test_round_trips
    cases = [
      ["a\nb\nc\n", "a\nB\nc\n"],          # replace middle line
      ["a\nb\nc\n", "a\nc\n"],             # delete middle line
      ["a\nc\n", "a\nb\nc\n"],             # insert middle line
      ["a\nb", "a\nb\nc"],                 # append line without trailing newline
      ["a\nb\n", "a\nb\nc\n"],             # append line with trailing newline
      ["a\nb\nc", "a\nb"],                 # delete last line
      ["a\nb\n", "a\nb"],                  # remove trailing newline
      ["a\nb", "a\nb\n"],                  # add trailing newline
      ["", "x\ny"],                        # from empty
      ["x\ny", ""],                        # to empty
      ["a\nb\nc\nd\ne", "a\nX\nY\nZ\nW\ne"], # grow in the middle
      ["a\nb\nc\nd\ne", "a\nX\ne"],        # shrink in the middle
      ["  if a\n    b; end\n  \n", "  if a\n    b\n    c; end\n  \n"], # `end` moving lines
      ["x", "y"],                          # single line, no newline
      ["a\na\na\n", "a\na\n"],             # repeated lines
      ["a\n", "a\n\n\n"],                  # blank lines appended
    ]

    cases.each do |old_text, new_text|
      change = HamlLsp::ShadowDiff.change(old_text, new_text, ENCODING)
      assert_equal new_text, apply(old_text, change), "#{old_text.inspect} -> #{new_text.inspect}"
    end
  end

  def test_random_edits_round_trip
    rng = Random.new(42)
    alphabet = ["a", "b", "c", "", "  ; end", "= foo"]

    200.times do
      old_lines = Array.new(rng.rand(0..6)) { alphabet.sample(random: rng) }
      new_lines = old_lines.dup
      rng.rand(0..3).times do
        case rng.rand(3)
        when 0 then new_lines.insert(rng.rand(0..new_lines.size), alphabet.sample(random: rng))
        when 1 then new_lines.delete_at(rng.rand(new_lines.size)) unless new_lines.empty?
        when 2 then new_lines[rng.rand(new_lines.size)] = alphabet.sample(random: rng) unless new_lines.empty?
        end
      end
      old_text = old_lines.join("\n")
      new_text = new_lines.join("\n")

      change = HamlLsp::ShadowDiff.change(old_text, new_text, ENCODING)
      assert_equal new_text, apply(old_text, change), "#{old_text.inspect} -> #{new_text.inspect}"
    end
  end

  private

  # Applies the change the way ruby-lsp does (character offsets in the negotiated encoding).
  def apply(text, change)
    return text if change.nil?

    text = text.dup
    range = change[:range]
    start_offset = ENCODING.offset(text, range[:start][:line], range[:start][:character])
    end_offset = ENCODING.offset(text, range[:end][:line], range[:end][:character])
    text[start_offset...end_offset] = change[:text]
    text
  end
end
