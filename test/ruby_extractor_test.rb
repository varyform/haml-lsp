# frozen_string_literal: true

require_relative "test_helper"

# Expected shadows are written with `·` in place of spaces so alignment is
# visible. HAML samples use non-interpolating heredocs because `#{}` is
# meaningful in both languages.
class RubyExtractorTest < Minitest::Test
  include ExtractorAssertions

  def test_empty_source
    assert_equal "", extract("")
  end

  def test_plain_markup_is_blanked
    assert_extracts <<~'RUBY', <<~'HAML'
      ·····
      ·······
      ····················
    RUBY
      %html
        %body
          %p Hello, world!
    HAML
  end

  def test_output_script
    assert_extracts <<~'RUBY', <<~'HAML'
      ··link_to "Home", root_path
    RUBY
      = link_to "Home", root_path
    HAML
  end

  def test_output_script_variants
    assert_extracts <<~'RUBY', <<~'HAML'
      ·· raw_html
      ·· escaped
      · preserved
      ··················text;
    RUBY
      != raw_html
      &= escaped
      ~ preserved
      == Interpolated #{text}
    HAML
  end

  def test_silent_script_block_gets_an_end
    assert_extracts <<~'RUBY', <<~'HAML'
      · if admin?
      ··········; end
      ···
    RUBY
      - if admin?
        %p Admin
      %hr
    HAML
  end

  def test_silent_script_without_children_gets_no_end
    assert_extracts <<~'RUBY', <<~'HAML'
      · foo = 1
      · bar(foo)
    RUBY
      - foo = 1
      - bar(foo)
    HAML
  end

  def test_if_elsif_else
    assert_extracts <<~'RUBY', <<~'HAML'
      · if a
      ····x
      · elsif b
      ····y
      · else
      ····z; end
    RUBY
      - if a
        = x
      - elsif b
        = y
      - else
        = z
    HAML
  end

  def test_case_when
    assert_extracts <<~'RUBY', <<~'HAML'
      · case role
      · when :admin
      ·············
      · when :user
      ············; end
      ··
    RUBY
      - case role
      - when :admin
        %span Admin
      - when :user
        %span User
      %p
    HAML
  end

  def test_begin_rescue_ensure
    assert_extracts <<~'RUBY', <<~'HAML'
      · begin
      ····risky
      · rescue StandardError => e
      ····log(e)
      · ensure
      ····cleanup; end
    RUBY
      - begin
        = risky
      - rescue StandardError => e
        = log(e)
      - ensure
        = cleanup
    HAML
  end

  def test_nested_blocks_close_in_order
    assert_extracts <<~'RUBY', <<~'HAML'
      · items.each do |item|
      ··· if item.visible?
      ······item.name; end; end
      ·······
    RUBY
      - items.each do |item|
        - if item.visible?
          = item.name
      %p Done
    HAML
  end

  def test_output_block
    assert_extracts <<~'RUBY', <<~'HAML'
      ··form_for @user do |f|
      ····f.text_field :name; end
    RUBY
      = form_for @user do |f|
        = f.text_field :name
    HAML
  end

  def test_block_with_spaced_pipes_is_not_multiline
    assert_extracts <<~'RUBY', <<~'HAML'
      · items.each do | item |
      ····item; end
    RUBY
      - items.each do | item |
        = item
    HAML
  end

  def test_block_whose_last_child_is_a_ruby_comment
    assert_extracts <<~'RUBY', <<~'HAML'
      · if a
      ····b
      ···················; end
      ··
    RUBY
      - if a
        = b
        - # trailing note
      %p
    HAML
  end

  def test_tag_with_inline_script
    assert_extracts <<~'RUBY', <<~'HAML'
      ·········; page_title
    RUBY
      %h1#title= page_title
    HAML
  end

  def test_tag_attribute_hash
    assert_extracts <<~'RUBY', <<~'HAML'
      ········{ class: klass, data: { id: record.id } }; body
    RUBY
      %div.box{ class: klass, data: { id: record.id } }= body
    HAML
  end

  def test_old_style_attribute_hash
    assert_extracts <<~'RUBY', <<~'HAML'
      ··{:href => url, "data-x" => 1}
    RUBY
      %a{:href => url, "data-x" => 1}
    HAML
  end

  def test_multiline_attribute_hash
    assert_extracts <<~'RUBY', <<~'HAML'
      ····{ class: klass,
            data: { id: record.id } }; body
      ···········
    RUBY
      %div{ class: klass,
            data: { id: record.id } }= body
        %p nested
    HAML
  end

  def test_html_style_attributes
    assert_extracts <<~'RUBY', <<~'HAML'
      ········url;······"Hi #{name}";·········
    RUBY
      %a(href=url title="Hi #{name}" disabled)
    HAML
  end

  def test_html_style_attributes_multiline
    assert_extracts <<~'RUBY', <<~'HAML'
      ········@url
      ;············'x'·; text
    RUBY
      %a(href=@url
             title='x')= text
    HAML
  end

  def test_object_reference
    assert_extracts <<~'RUBY', <<~'HAML'
      ···[post, :summary]
    RUBY
      %li[post, :summary]
    HAML
  end

  def test_tag_modifiers_and_self_closing
    assert_extracts <<~'RUBY', <<~'HAML'
      ····{ src: url }···
      ··················
    RUBY
      %img{ src: url }/><
      %br/ trailing text
    HAML
  end

  def test_interpolation_in_plain_text
    assert_extracts <<~'RUBY', <<~'HAML'
      ···········user.name;·······················
      ········· [1, { nested: 1 }].size ;
    RUBY
      %p Hello #{user.name}, you have \#{not_ruby}
      Second #{ [1, { nested: 1 }].size }
    HAML
  end

  def test_interpolation_in_escaped_and_html_comment_lines
    assert_extracts <<~'RUBY', <<~'HAML'
      ·············a;
      ············b;
      ································
      ··············c;
      ············d;
    RUBY
      \= literal #{a}
      / comment #{b}
      /[if IE] conditional #{not_ruby}
      ! unescaped #{c}
      & escaped #{d}
    HAML
  end

  def test_haml_comment_hides_nested_lines
    assert_extracts <<~'RUBY', <<~'HAML'
      ·················
      ····················
      ···················
      · after
    RUBY
      -# a comment #{x}
        - this is not ruby
        = neither is this
      - after
    HAML
  end

  def test_ruby_filter_is_verbatim
    assert_extracts <<~'RUBY', <<~'HAML'
      ·····
        total = items.sum(&:price)
        label = total.zero? ? "free" : number_to_currency(total)
      ··; 1 == 1 ? "same" : "diff"
    RUBY
      :ruby
        total = items.sum(&:price)
        label = total.zero? ? "free" : number_to_currency(total)
      %p= 1 == 1 ? "same" : "diff"
    HAML
  end

  def test_other_filters_keep_only_interpolation
    assert_extracts <<~'RUBY', <<~'HAML'
      ···········
      ····················································count;··
      ····
      ··················theme_color;···
      ·································
    RUBY
      :javascript
        document.getElementById("app").dataset.count = "#{count}";
      :css
        body { color: #{theme_color}; }
        .p { content: "curly } fine"; }
    HAML
  end

  def test_filter_block_as_block_child
    assert_extracts <<~'RUBY', <<~'HAML'
      · if a
      ·······
          x = 1; end
      ··
    RUBY
      - if a
        :ruby
          x = 1
      %p
    HAML
  end

  def test_pipe_multiline_script
    assert_extracts <<~'RUBY', <<~'HAML'
      ··link_to "A very long label",··
      ·········path_for(record),··
      ·········class: "btn"··
      ··
    RUBY
      = link_to "A very long label", |
               path_for(record), |
               class: "btn" |
      %p
    HAML
  end

  def test_comma_multiline_script
    assert_extracts <<~'RUBY', <<~'HAML'
      ··render partial: "row",
        locals: { row: row },
        cached: true
      ··
    RUBY
      = render partial: "row",
        locals: { row: row },
        cached: true
      %p
    HAML
  end

  def test_block_end_lands_after_multiline_continuation
    assert_extracts <<~'RUBY', <<~'HAML'
      · rows.each do |row|
      ····render "row",
               row: row; end
      ··
    RUBY
      - rows.each do |row|
        = render "row",
               row: row
      %p
    HAML
  end

  def test_doctype_is_blanked
    assert_extracts <<~'RUBY', <<~'HAML'
      ·····
      ··········
    RUBY
      !!! 5
      !!! Strict
    HAML
  end

  def test_windows_line_endings_are_preserved
    haml = "- if a\r\n  %p\r\n%p\r\n"
    ruby = HamlLsp::RubyExtractor.extract(haml)

    assert_equal "  if a\r\n    ; end\r\n  \r\n", ruby
    assert_parses(ruby)
  end

  def test_blank_lines_do_not_close_blocks
    assert_extracts <<~'RUBY', <<~'HAML'
      · if a

      ····b

      ····c; end
      ··
    RUBY
      - if a

        = b

        = c
      %p
    HAML
  end

  def test_unclosed_block_at_end_of_file
    assert_extracts <<~'RUBY', <<~'HAML'
      · items.each do |i|
      ····i; end
    RUBY
      - items.each do |i|
        = i
    HAML
  end

  def test_tabs_are_preserved
    haml = "- if a\n\t= b\n%p\n"
    ruby = HamlLsp::RubyExtractor.extract(haml)

    assert_equal "  if a\n\t  b; end\n  \n", ruby
    assert_parses(ruby)
  end

  def test_non_ascii_plain_text_keeps_utf16_widths
    utf16 = HamlLsp::PositionEncoding.new(HamlLsp::PositionEncoding::UTF16)
    haml = "%p Привіт 🎉 \#{name} 日本\n"
    ruby = extract(haml, encoding: utf16)

    # "%p Привіт 🎉 " is 3 + 6 + 1 + 2 (emoji is a surrogate pair) + 1 = 13 code units.
    assert_equal " " * 13 + "  name;" + " " * 3 + "\n", ruby
    assert_parses(ruby)
  end

  def test_non_ascii_plain_text_keeps_utf8_widths
    utf8 = HamlLsp::PositionEncoding.new(HamlLsp::PositionEncoding::UTF8)
    haml = "%p Привіт \#{name}\n"
    ruby = extract(haml, encoding: utf8)

    # "%p " (3 bytes) + "Привіт" (12 bytes) + " " (1 byte)
    assert_equal " " * 16 + "  name;\n", ruby
  end

  def test_non_ascii_inside_ruby_is_kept_verbatim
    utf8 = HamlLsp::PositionEncoding.new(HamlLsp::PositionEncoding::UTF8)
    haml = "= t(\"привіт\")\n"
    assert_equal "  t(\"привіт\")\n", extract(haml, encoding: utf8)
  end

  def test_half_typed_input_does_not_raise
    snippets = [
      "%div{",
      "%div{ class: ",
      "%a(href=",
      "%a(href=\"unterminated",
      "%p \#{unclosed",
      "- if",
      "=",
      "-",
      ":",
      "%",
      "\#{",
      "%p= foo do |x|",
      "- else",
      "  - when 1\n    %p\n- x",
      "%p{a: 1,\n",
      "= foo, |\n",
      "= foo,\n",
    ]

    snippets.each do |haml|
      ruby = HamlLsp::RubyExtractor.extract(haml)
      assert_position_preserving(haml, ruby)
    end
  end

  def test_fixture_is_valid_haml_and_valid_ruby
    haml = File.read(File.expand_path("fixtures/show.html.haml", __dir__))
    ruby = extract(haml)
    assert_parses(ruby)
  end
end
