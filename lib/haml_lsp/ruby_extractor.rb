# frozen_string_literal: true

require "strscan"
require "prism"

module HamlLsp
  # Turns a HAML template into a Ruby "shadow" document.
  #
  # The shadow has exactly the same number of lines as the template and, for
  # every line, the first N code units (N = length of the original line) are
  # either the original character (when it is part of an embedded Ruby
  # fragment) or a space / `;` placeholder (when it is HAML markup or plain
  # text). Anything the shadow needs that the template does not have -- most
  # notably the `end` keywords closing indentation-delimited blocks -- is
  # appended *after* the end of the line, so it never shifts a column.
  #
  # Because of this, an LSP position in the template is the same position in
  # the shadow, and vice versa. That lets us hand the shadow to ruby-lsp as a
  # regular Ruby document and forward its answers untouched. This is the same
  # trick ruby-lsp itself uses for ERB.
  #
  # Widths are measured in the negotiated LSP position encoding so that
  # non-ASCII plain text still lines up.
  class RubyExtractor
    MID_BLOCK_KEYWORDS = %w[else elsif when in rescue ensure].freeze
    MID_BLOCK_RE = /\A-\s*(?:#{MID_BLOCK_KEYWORDS.join("|")})\b/
    TAG_HEAD_RE = /(?:%[-:\w]+)?(?:\.[-:\w]+|#[-:\w]+)*/
    HTML_ATTR_VALUE_RE = /(?:@@?|\$)?\w+/
    INTERPOLATION_START = '#{'

    def self.extract(source, encoding: PositionEncoding.new)
      new(source, encoding: encoding).extract
    end

    def initialize(source, encoding: PositionEncoding.new)
      @source = source
      @enc = encoding
    end

    def extract
      return "" if @source.empty?

      @lines = @source.split("\n", -1)
      @out = Array.new(@lines.size)
      @appends = Hash.new { |h, k| h[k] = [] }
      @stack = []            # open script blocks: { indent:, has_children: }
      @last_content = nil    # index of the last line that carries content
      @region = nil          # { kind: :comment | :filter_ruby | :filter_plain, indent: }
      @continuation = nil    # multi-line construct carried over from the previous line

      @lines.each_with_index { |line, index| process_line(line, index) }
      close_blocks(-1)

      blank_ruby_comments!
      assemble
    end

    private

    # ------------------------------------------------------------------
    # Line dispatch
    # ------------------------------------------------------------------

    def process_line(raw, index)
      line = raw.chomp("\r")

      if @continuation
        return if continue_line(line, index)
      end

      if line.strip.empty?
        @out[index] = line
        return
      end

      indent = line[/\A[ \t]*/].length

      if @region
        if indent > @region[:indent]
          @out[index] = region_line(line)
          @last_content = index
          return
        end

        @region = nil
      end

      content = line[indent..]
      continued = close_blocks(indent, mid_block: content.match?(MID_BLOCK_RE))
      mark_children(indent)
      @last_content = index

      prefix = line[0, indent]
      @out[index] = prefix + dispatch(content, index, indent, continued)
    end

    def dispatch(content, index, indent, continued)
      case content
      when /\A-#/
        @region = { kind: :comment, indent: indent }
        blank(content)
      when /\A-/
        push_block(indent) unless continued
        " " + ruby_script(content[1..], index)
      when /\A!!!/
        blank(content)
      when /\A(==|!==|&==)/
        op = Regexp.last_match(1)
        blank(op) + plain_text(content[op.length..])
      when /\A(=|!=|&=|~)/
        op = Regexp.last_match(1)
        push_block(indent)
        blank(op) + ruby_script(content[op.length..], index)
      when /\A[!&]/
        " " + plain_text(content[1..])
      when /\A%[-:\w]/, /\A\.[-:\w]/, /\A#(?!\{)/
        tag(content, index)
      when /\A:(\w*)/
        name = Regexp.last_match(1)
        @region = { kind: name == "ruby" ? :filter_ruby : :filter_plain, indent: indent }
        blank(content)
      when %r{\A/\[}
        blank(content)
      when %r{\A/}
        " " + plain_text(content[1..])
      when /\A\\/
        " " + plain_text(content[1..])
      else
        plain_text(content)
      end
    end

    def region_line(line)
      case @region[:kind]
      when :filter_ruby then line
      when :filter_plain then plain_text(line)
      else blank(line)
      end
    end

    # ------------------------------------------------------------------
    # Blocks (`- if foo` ... dedent => `end`)
    # ------------------------------------------------------------------

    def push_block(indent)
      @stack << { indent: indent, has_children: false }
    end

    def mark_children(indent)
      top = @stack.last
      top[:has_children] = true if top && indent > top[:indent]
    end

    # Pops every block that the line at `indent` closes. Returns true when the
    # line is a mid-block keyword (else/when/rescue/...) continuing the block
    # at the same indentation, in which case that block stays open.
    def close_blocks(indent, mid_block: false)
      pop_block while (top = @stack.last) && top[:indent] > indent

      top = @stack.last
      return false unless top && top[:indent] == indent
      return true if mid_block

      pop_block
      false
    end

    def pop_block
      block = @stack.pop
      return unless block[:has_children] && @last_content

      @appends[@last_content] << "; end"
    end

    # ------------------------------------------------------------------
    # Ruby fragments
    # ------------------------------------------------------------------

    # `text` is the Ruby following `-`, `=`, `~` etc. Handles HAML's two
    # multiline forms: a trailing ` |` marker, and a trailing comma.
    def ruby_script(text, _index)
      if pipe_multiline?(text)
        @continuation = { kind: :ruby_pipe }
        strip_pipe(text)
      elsif comma_multiline?(text)
        @continuation = { kind: :ruby_comma }
        text
      else
        text
      end
    end

    # Mirrors Haml::Parser#is_multiline? (including its `do | x |` exception).
    def pipe_multiline?(text)
      stripped = text.rstrip
      stripped.length > 1 && stripped.end_with?("|") && stripped[-2] == " " &&
        !stripped.match?(/do\s*\|\s*[^|]*\s+\|\z/)
    end

    # Mirrors Haml::Parser#is_ruby_multiline?
    def comma_multiline?(text)
      stripped = text.rstrip
      stripped.length > 1 && stripped.end_with?(",") &&
        !(stripped[-3, 2].to_s.match?(/\W\?/) || stripped[-3, 2] == "?\\")
    end

    def strip_pipe(text)
      pipe = text.rindex("|")
      text[0...pipe] + " " + text[(pipe + 1)..]
    end

    # Plain text: everything is blanked except `#{...}` interpolations, whose
    # Ruby is kept and turned into a statement (`#{` -> spaces, `}` -> `;`).
    def plain_text(text)
      out = +""
      pos = 0

      while (start = text.index(INTERPOLATION_START, pos))
        if start.positive? && text[start - 1] == "\\"
          out << blank(text[pos..start])
          pos = start + 1
          next
        end

        close = matching_brace(text, start + 2)
        out << blank(text[pos...start]) << "  "

        if close
          out << text[(start + 2)...close] << ";"
          pos = close + 1
        else
          out << text[(start + 2)..]
          return out
        end
      end

      out << blank(text[pos..])
    end

    # Index of the `}` closing an interpolation / attribute hash whose body
    # starts at `from`, or nil when unbalanced. Plain depth counting, which is
    # what HAML itself does.
    def matching_brace(text, from, open: "{", close: "}", depth: 1)
      i = from
      while i < text.length
        char = text[i]
        if char == open
          depth += 1
        elsif char == close
          depth -= 1
          return i if depth.zero?
        end
        i += 1
      end
      nil
    end

    # ------------------------------------------------------------------
    # Tags
    # ------------------------------------------------------------------

    def tag(content, index)
      scanner = StringScanner.new(content)
      out = +""
      out << blank(scanner.scan(TAG_HEAD_RE).to_s)
      out << tag_attributes_and_rest(scanner, index)
      out
    end

    # Attribute groups (`{}`, `()`, `[]` in any order), whitespace modifiers,
    # then either inline script or inline plain text. Also used to resume a tag
    # whose attribute group spilled over to the next line.
    def tag_attributes_and_rest(scanner, index)
      out = +""

      loop do
        case scanner.peek(1)
        when "{"
          scanner.getch
          out << "{"
          close = matching_brace(scanner.rest, 0)
          if close
            out << scanner.rest[0..close]
            scanner.pos += scanner.rest[0..close].bytesize
          else
            out << scanner.rest
            @continuation = { kind: :attr_hash, depth: brace_depth(scanner.rest, 1) }
            return out
          end
        when "["
          scanner.getch
          out << "["
          close = matching_brace(scanner.rest, 0, open: "[", close: "]")
          if close
            out << scanner.rest[0..close]
            scanner.pos += scanner.rest[0..close].bytesize
          else
            out << scanner.rest
            @continuation = { kind: :attr_hash, depth: brace_depth(scanner.rest, 1, open: "[", close: "]"),
                              open: "[", close: "]" }
            return out
          end
        when "("
          scanner.getch
          processed, closed, state = html_attributes(scanner.rest)
          out << " " << processed
          if closed
            scanner.pos += scanner.rest.bytesize - state[:remaining].bytesize
          else
            @continuation = { kind: :attr_html, state: state }
            return out
          end
        else
          break
        end
      end

      out << blank(scanner.scan(%r{[<>]*/?}).to_s)
      out << tag_inline_content(scanner.rest, index)
      out
    end

    def tag_inline_content(rest, index)
      case rest
      when /\A(==|!==|&==)/
        op = Regexp.last_match(1)
        blank(op) + plain_text(rest[op.length..])
      when /\A(=|!=|&=|~)/
        op = Regexp.last_match(1)
        # `;` separates the attribute hash / object reference expression from
        # the inline script so the shadow stays two statements.
        (" " * (op.length - 1)) + ";" + ruby_script(rest[op.length..], index)
      when /\A\s*\z/
        blank(rest)
      else
        text = plain_text(rest)
        if pipe_multiline?(rest)
          @continuation = { kind: :plain_pipe }
          strip_pipe(text)
        else
          text
        end
      end
    end

    def brace_depth(text, depth, open: "{", close: "}")
      text.each_char do |char|
        depth += 1 if char == open
        depth -= 1 if char == close
      end
      depth
    end

    # HTML-style attributes: `(href=@url title="Hi #{name}" disabled)`.
    # Keys and `=` are blanked, values are kept as Ruby expressions separated
    # by `;` so they read as independent statements. Returns
    # [processed_text, closed?, state]. `state[:remaining]` is what follows
    # the closing paren when closed.
    def html_attributes(text, state = { after_value: false })
      scanner = StringScanner.new(text)
      out = +""

      until scanner.eos?
        if (ws = scanner.scan(/[ \t]+/))
          if state[:after_value]
            out << ";" << blank(ws[1..])
            state[:after_value] = false
          else
            out << ws
          end
          next
        end

        if scanner.scan(/\)/)
          out << " "
          state[:remaining] = scanner.rest
          return [out, true, state]
        end

        if (name = scanner.scan(/[-:\w]+/))
          out << blank(name)
          state[:after_value] = false
          out << scanner.scan(/[ \t]*/).to_s
          next unless scanner.scan(/=/)

          out << " "
          out << scanner.scan(/[ \t]*/).to_s

          if (quote = scanner.scan(/["']/))
            body = quoted_string_body(scanner.rest, quote)
            out << quote << body
            scanner.pos += body.bytesize
            state[:after_value] = true
          elsif (value = scanner.scan(HTML_ATTR_VALUE_RE))
            out << value
            state[:after_value] = true
          end
          next
        end

        # Anything HAML itself would reject. Keep the statement separator so a
        # half-typed attribute list still yields parseable Ruby.
        garbage = blank(scanner.getch)
        out << (state[:after_value] ? ";" + garbage[1..] : garbage)
        state[:after_value] = false
      end

      [out, false, state]
    end

    # The body of a quoted string including the closing quote (if present),
    # honouring backslash escapes and `#{}` interpolation.
    def quoted_string_body(text, quote)
      i = 0
      while i < text.length
        char = text[i]
        if char == "\\"
          i += 2
        elsif char == "#" && text[i + 1] == "{"
          close = matching_brace(text, i + 2)
          return text if close.nil?

          i = close + 1
        elsif char == quote
          return text[0..i]
        else
          i += 1
        end
      end
      text
    end

    # ------------------------------------------------------------------
    # Multi-line constructs
    # ------------------------------------------------------------------

    # Returns true when the line was consumed as part of the continuation.
    def continue_line(line, index)
      kind = @continuation[:kind]

      case kind
      when :ruby_pipe
        unless pipe_multiline?(line)
          @continuation = nil
          return false
        end
        @out[index] = strip_pipe(line)
        @last_content = index
        true
      when :plain_pipe
        unless pipe_multiline?(line)
          @continuation = nil
          return false
        end
        @out[index] = strip_pipe(plain_text(line))
        @last_content = index
        true
      when :ruby_comma
        @continuation = nil unless comma_multiline?(line)
        @out[index] = line
        @last_content = index
        true
      when :attr_hash
        open = @continuation[:open] || "{"
        close = @continuation[:close] || "}"
        close_at = matching_brace(line, 0, open: open, close: close, depth: @continuation[:depth])
        if close_at
          @continuation = nil
          scanner = StringScanner.new(line)
          scanner.pos = line[0..close_at].bytesize
          @out[index] = line[0..close_at] + tag_attributes_and_rest(scanner, index)
        else
          @continuation[:depth] = brace_depth(line, @continuation[:depth], open: open, close: close)
          @out[index] = line
        end
        @last_content = index
        true
      when :attr_html
        processed, closed, state = html_attributes(line, @continuation[:state])
        if closed
          @continuation = nil
          scanner = StringScanner.new(line)
          scanner.pos = line.bytesize - state[:remaining].bytesize
          @out[index] = processed + tag_attributes_and_rest(scanner, index)
        else
          @out[index] = processed
        end
        @last_content = index
        true
      else
        @continuation = nil
        false
      end
    end

    # ------------------------------------------------------------------
    # Assembly
    # ------------------------------------------------------------------

    # Ruby comments (`- # note`, `= foo # note`) would swallow anything we
    # append to their line, so blank them out. One Prism lex over the whole
    # shadow is cheaper than being clever per line.
    def blank_ruby_comments!
      joined = @out.join("\n")
      result = Prism.lex(joined)
      comments = result.value.select { |token, _| token.type == :COMMENT }.map(&:first)
      return if comments.empty?

      comments.each do |token|
        loc = token.location
        line = loc.start_line - 1
        text = @out[line]
        next unless text

        # Comment tokens include the trailing newline, so `end_column` can be
        # on the next line; the comment itself always ends with its own line.
        start_col = text.byteslice(0, loc.start_column).length
        text[start_col..] = blank(text[start_col..])
      end
    end

    def assemble
      @out.each_with_index.map do |text, index|
        text = text.to_s + @appends[index].join if @appends.key?(index)
        @lines[index].end_with?("\r") ? "#{text}\r" : text
      end.join("\n")
    end

    def blank(string)
      @enc.blank(string.to_s)
    end
  end
end
