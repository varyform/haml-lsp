# frozen_string_literal: true

require_relative "test_helper"

class RubyDiagnosticsTest < Minitest::Test
  # Every construct the extractor supports, in valid form. None of these may
  # yield a Ruby diagnostic -- a failure here means the shadow itself is wrong.
  VALID_TEMPLATES = [
    File.read(File.expand_path("fixtures/show.html.haml", __dir__)),
    "= link_to \"Home\", root_path\n",
    "!= raw_html\n&= escaped\n~ preserved\n== Interpolated \#{text}\n",
    "- if a\n  = x\n- elsif b\n  = y\n- else\n  = z\n",
    "- case role\n- when :admin\n  %span Admin\n- when :user\n  %span User\n%p\n",
    "- begin\n  = risky\n- rescue StandardError => e\n  = log(e)\n- ensure\n  = cleanup\n",
    "- items.each do |item|\n  - if item.visible?\n    = item.name\n%p Done\n",
    "= form_for @user do |f|\n  = f.text_field :name\n",
    "- items.each do | item |\n  = item\n",
    "- if a\n  = b\n  - # trailing note\n%p\n",
    "%h1#title= page_title\n",
    "%div.box{ class: klass, data: { id: record.id } }= body\n",
    "%a{:href => url, \"data-x\" => 1}\n",
    "%div{ class: klass,\n      data: { id: record.id } }= body\n  %p nested\n",
    "%a(href=url title=\"Hi \#{name}\" disabled)\n",
    "%a(href=@url\n       title='x')= text\n",
    "%li[post, :summary]\n",
    "%img{ src: url }/><\n%br/ trailing text\n",
    "%p Hello \#{user.name}, you have \\\#{not_ruby}\nSecond \#{ [1, { nested: 1 }].size }\n",
    "\\= literal \#{a}\n/ comment \#{b}\n/[if IE] conditional \#{not_ruby}\n! unescaped \#{c}\n& escaped \#{d}\n",
    "-# a comment \#{x}\n  - this is not ruby\n  = neither is this\n- after\n",
    ":ruby\n  total = items.sum(&:price)\n  label = total.zero? ? \"free\" : number_to_currency(total)\n%p= 1 == 1 ? \"same\" : \"diff\"\n",
    ":javascript\n  document.getElementById(\"app\").dataset.count = \"\#{count}\";\n:css\n  body { color: \#{theme_color}; }\n",
    "- if a\n  :ruby\n    x = 1\n%p\n",
    "= link_to \"A very long label\", |\n         path_for(record), |\n         class: \"btn\" |\n%p\n",
    "= render partial: \"row\",\n  locals: { row: row },\n  cached: true\n%p\n",
    "- rows.each do |row|\n  = render \"row\",\n         row: row\n%p\n",
    "!!! 5\n!!! Strict\n",
    "- if a\r\n  %p\r\n%p\r\n",
    "- if a\n\n  = b\n\n  = c\n%p\n",
    "%p Привіт \#{name} 日本\n",
    "= t(\"привіт\")\n",
    "%p\n  = yield\n  = yield :sidebar\n  - break if done?\n",
    "- content_for :title do\n  Page\n%p= content_for(:title)\n",
    "%td= number_to_currency(row.total) if row.total?\n",
    "- @posts.each_with_index do |post, i|\n  %li{ class: (\"odd\" if i.odd?) }= post.title\n",
  ].freeze

  def test_valid_templates_have_no_ruby_diagnostics
    VALID_TEMPLATES.each do |haml|
      diagnostics = HamlLsp::RubyDiagnostics.for(document(haml))
      assert_empty diagnostics, "false positive for:\n#{haml}\n#{diagnostics.map { |d| d[:message] }.join("\n")}"
    end
  end

  def test_error_inside_ruby_is_reported_in_place
    diagnostics = HamlLsp::RubyDiagnostics.for(document("%p= @user.\n"))

    assert_equal 1, diagnostics.size
    diagnostic = diagnostics.first
    assert_equal "ruby", diagnostic[:source]
    assert_equal HamlLsp::RubyDiagnostics::SEVERITY_ERROR, diagnostic[:severity]
    # The error is at end of input (column 10); the range is widened to the `.`
    # so editors have something to underline.
    assert_equal({ start: { line: 0, character: 9 }, end: { line: 0, character: 10 } }, diagnostic[:range])
    assert_match(/expecting a message/, diagnostic[:message])
  end

  def test_unclosed_paren_is_anchored_to_the_ruby_line
    # Prism reports this at end-of-input on the `%p` line, which has no Ruby.
    diagnostics = HamlLsp::RubyDiagnostics.for(document("= link_to(\"x\"\n%p\n"))

    assert_equal 1, diagnostics.size
    assert_equal({ start: { line: 0, character: 1 }, end: { line: 0, character: 13 } }, diagnostics.first[:range])
    assert_match(/expected a `\)`/, diagnostics.first[:message])
  end

  def test_missing_predicate
    diagnostics = HamlLsp::RubyDiagnostics.for(document("- if\n  %p\n%hr\n"))

    assert_equal 1, diagnostics.size
    assert_equal 0, diagnostics.first[:range][:start][:line]
    assert_match(/predicate/, diagnostics.first[:message])
  end

  def test_block_without_children_needs_an_end
    diagnostics = HamlLsp::RubyDiagnostics.for(document("- if a\n%p\n"))

    assert_equal 1, diagnostics.size
    assert_equal 0, diagnostics.first[:range][:start][:line]
    assert_match(/end/, diagnostics.first[:message])
  end

  def test_one_diagnostic_per_line_and_in_zone_errors_win
    # Prism produces a cascade of 7 errors for this single mistake.
    diagnostics = HamlLsp::RubyDiagnostics.for(document("= foo(1,, 2)\n"))

    assert_equal 1, diagnostics.size
    assert_equal 8, diagnostics.first[:range][:start][:character]
  end

  def test_ranges_are_never_empty
    ["%p= @user.\n", "= foo(\n", "- x = [1, 2\n%p\n", "= \"unterminated\n", "%p= \n", "- if\n  %p\n", "= \n  %p\n"].each do |haml|
      HamlLsp::RubyDiagnostics.for(document(haml)).each do |d|
        assert d[:range][:end][:character] > d[:range][:start][:character] || d[:range][:end][:line] > d[:range][:start][:line],
               "empty range for #{haml.inspect}: #{d.inspect}"
      end
    end
  end

  def test_errors_are_capped
    haml = Array.new(30) { |i| "= foo(#{i},, 2)" }.join("\n") + "\n"
    assert_equal HamlLsp::RubyDiagnostics::MAX_DIAGNOSTICS, HamlLsp::RubyDiagnostics.for(document(haml)).size
  end

  def test_non_ascii_positions_use_the_encoding
    utf16 = HamlLsp::PositionEncoding.new(HamlLsp::PositionEncoding::UTF16)
    diagnostics = HamlLsp::RubyDiagnostics.for(document("%p 🎉 \#{user.}\n", encoding: utf16))

    assert_equal 1, diagnostics.size
    # "%p 🎉 #{" is 3 + 2 + 1 + 2 = 8 units; "user." ends at 13.
    assert_equal({ start: { line: 0, character: 13 }, end: { line: 0, character: 14 } }, diagnostics.first[:range])
  end

  def test_combined_diagnostics_prefer_haml_errors
    combined = HamlLsp::Diagnostics.for(document("%div\n  %p= @user.\n %span\n"))
    assert_equal ["haml"], combined.map { |d| d[:source] }

    combined = HamlLsp::Diagnostics.for(document("%div\n  %p= @user.\n"))
    assert_equal ["ruby"], combined.map { |d| d[:source] }
  end

  private

  def document(source, encoding: HamlLsp::PositionEncoding.new)
    HamlLsp::Document.new(uri: "file:///x.haml", source: source, version: 1, encoding: encoding)
  end
end
