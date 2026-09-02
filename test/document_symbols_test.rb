# frozen_string_literal: true

require_relative "test_helper"

class DocumentSymbolsTest < Minitest::Test
  def test_outline_of_tags_and_filters
    symbols = symbols_for(<<~'HAML')
      !!! 5
      %html
        %head
          %title= page_title
          :javascript
            init();
        %body.app#main
          - if admin?
            .banner Admin
          %p Hello #{name}
      %footer
    HAML

    assert_equal %w[%html %footer], symbols.map { |s| s[:name] }

    html = symbols.first
    assert_equal HamlLsp::DocumentSymbols::KIND_FIELD, html[:kind]
    assert_equal({ start: { line: 1, character: 0 }, end: { line: 9, character: 20 } }, html[:range])
    assert_equal({ start: { line: 1, character: 0 }, end: { line: 1, character: 5 } }, html[:selectionRange])
    assert_equal %w[%head %body.app#main], html[:children].map { |s| s[:name] }

    head = html[:children][0]
    assert_equal %w[%title :javascript], head[:children].map { |s| s[:name] }
    assert_equal HamlLsp::DocumentSymbols::KIND_MODULE, head[:children][1][:kind]
    assert_equal 5, head[:children][1][:range][:end][:line]

    body = html[:children][1]
    # `.banner` sits under `- if`, which is not a symbol, so it becomes a child of %body.
    assert_equal %w[.banner %p], body[:children].map { |s| s[:name] }
    assert_equal({ start: { line: 8, character: 6 }, end: { line: 8, character: 13 } },
                 body[:children][0][:selectionRange])

    footer = symbols.last
    assert_equal({ start: { line: 10, character: 0 }, end: { line: 10, character: 7 } }, footer[:range])
  end

  def test_plain_text_and_scripts_produce_nothing
    assert_empty symbols_for("Hello\n= foo\n- bar\n\#{interp}\n")
  end

  def test_empty_document
    assert_empty symbols_for("")
  end

  private

  def symbols_for(source)
    HamlLsp::DocumentSymbols.for(HamlLsp::Document.new(uri: "file:///x.haml", source: source, version: 1))
  end
end
