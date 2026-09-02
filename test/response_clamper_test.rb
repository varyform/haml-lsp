# frozen_string_literal: true

require_relative "test_helper"

class ResponseClamperTest < Minitest::Test
  URI = "file:///app/views/x.html.haml"
  OTHER_HAML = "file:///app/views/y.html.haml"
  RUBY_FILE = "file:///app/models/user.rb"

  # Shadow of line 1 is "    b; end" (10 units) while the template line "  = b" is 5.
  def setup
    @documents = {
      URI => HamlLsp::Document.new(uri: URI, source: "- if a\n  = b\n%p\n", version: 1),
      OTHER_HAML => HamlLsp::Document.new(uri: OTHER_HAML, source: "= x\n", version: 1),
    }
    @clamper = HamlLsp::ResponseClamper.new(@documents, URI)
  end

  def test_positions_within_the_template_are_untouched
    hover = { contents: "x", range: range(1, 4, 1, 5) }
    assert_equal hover, @clamper.clamp(hover)
  end

  def test_positions_past_the_line_end_are_clamped
    hover = { contents: "x", range: range(1, 4, 1, 10) }
    assert_equal({ contents: "x", range: range(1, 4, 1, 5) }, @clamper.clamp(hover))
  end

  def test_items_pointing_only_at_appended_text_are_dropped
    highlights = [
      { range: range(0, 2, 0, 4), kind: 1 },   # `if`
      { range: range(1, 7, 1, 10), kind: 1 },  # `end`, appended
    ]
    assert_equal [highlights.first], @clamper.clamp(highlights)
  end

  def test_folding_ranges
    folds = [{ startLine: 0, startCharacter: 2, endLine: 1, endCharacter: 10, kind: "region" }]
    assert_equal [{ startLine: 0, startCharacter: 2, endLine: 1, endCharacter: 5, kind: "region" }], @clamper.clamp(folds)
  end

  def test_positions_beyond_the_last_line_clamp_to_zero
    assert_equal({ line: 9, character: 0 }, @clamper.clamp({ line: 9, character: 3 }))
  end

  def test_locations_in_other_files_are_left_alone
    definition = [{ uri: RUBY_FILE, range: range(3, 0, 3, 40) }]
    assert_equal definition, @clamper.clamp(definition)

    links = [{ targetUri: RUBY_FILE, targetRange: range(3, 0, 3, 40), targetSelectionRange: range(3, 6, 3, 40) }]
    assert_equal links, @clamper.clamp(links)
  end

  def test_locations_in_other_haml_documents_use_their_own_lengths
    references = [
      { uri: OTHER_HAML, range: range(0, 2, 0, 9) },
      { uri: URI, range: range(1, 4, 1, 9) },
    ]
    assert_equal [
      { uri: OTHER_HAML, range: range(0, 2, 0, 3) },
      { uri: URI, range: range(1, 4, 1, 5) },
    ], @clamper.clamp(references)
  end

  def test_workspace_edit_changes_and_document_changes
    edit = {
      changes: {
        URI.to_sym => [{ range: range(1, 4, 1, 9), newText: "c" }],
        RUBY_FILE.to_sym => [{ range: range(0, 0, 0, 99), newText: "c" }],
      },
      documentChanges: [
        { textDocument: { uri: URI, version: 1 }, edits: [{ range: range(1, 4, 1, 9), newText: "c" }] },
        { textDocument: { uri: RUBY_FILE, version: 1 }, edits: [{ range: range(0, 0, 0, 99), newText: "c" }] },
      ],
    }

    clamped = @clamper.clamp(edit)
    assert_equal range(1, 4, 1, 5), clamped[:changes][URI.to_sym].first[:range]
    assert_equal range(0, 0, 0, 99), clamped[:changes][RUBY_FILE.to_sym].first[:range]
    assert_equal range(1, 4, 1, 5), clamped[:documentChanges][0][:edits].first[:range]
    assert_equal range(0, 0, 0, 99), clamped[:documentChanges][1][:edits].first[:range]
  end

  def test_semantic_tokens_past_the_line_end_are_removed_and_deltas_rewritten
    # line 0: `if` at 2 (len 2); line 1: `b` at 4 (len 1), `end` at 7 (len 3, appended); line 2: nothing.
    tokens = { resultId: "1", data: [0, 2, 2, 15, 0, 1, 4, 1, 8, 0, 0, 3, 3, 15, 0] }

    assert_equal({ resultId: "1", data: [0, 2, 2, 15, 0, 1, 4, 1, 8, 0] }, @clamper.clamp(tokens))
  end

  def test_semantic_token_overlapping_the_line_end_is_shortened
    tokens = { data: [1, 4, 6, 8, 0] }
    assert_equal({ data: [1, 4, 1, 8, 0] }, @clamper.clamp(tokens))
  end

  def test_non_position_data_is_untouched
    items = { isIncomplete: false, items: [{ label: "div", data: { hamlLsp: true } }] }
    assert_equal items, @clamper.clamp(items)
  end

  def test_nested_document_symbols
    symbols = [{
      name: "x", kind: 13, range: range(1, 4, 1, 10), selectionRange: range(1, 4, 1, 5),
      children: [{ name: "y", kind: 13, range: range(1, 7, 1, 10), selectionRange: range(1, 7, 1, 10) }],
    }]

    clamped = @clamper.clamp(symbols)
    assert_equal range(1, 4, 1, 5), clamped.first[:range]
    assert_empty clamped.first[:children]
  end

  private

  def range(sl, sc, el, ec)
    { start: { line: sl, character: sc }, end: { line: el, character: ec } }
  end
end
