# frozen_string_literal: true

module HamlLsp
  # Helpers for the LSP position encodings (utf-8, utf-16, utf-32).
  #
  # LSP positions are expressed as {line, character} where `character` counts
  # code units of the negotiated encoding. Everything in haml-lsp that touches
  # positions goes through here so the shadow Ruby document lines up with the
  # HAML document in whichever encoding ruby-lsp and the editor agreed on.
  class PositionEncoding
    UTF8 = "utf-8"
    UTF16 = "utf-16"
    UTF32 = "utf-32"

    attr_reader :kind

    def self.from_lsp(kind)
      new(kind.nil? || kind.empty? ? UTF16 : kind)
    end

    def initialize(kind = UTF16)
      @kind = kind
    end

    # Number of code units a single character occupies.
    def width(char)
      case @kind
      when UTF8 then char.bytesize
      when UTF32 then 1
      else char.ord > 0xFFFF ? 2 : 1
      end
    end

    # Number of code units in a string.
    def length(string)
      return string.length if string.ascii_only?

      case @kind
      when UTF8 then string.bytesize
      when UTF32 then string.length
      else string.each_char.sum { |c| width(c) }
      end
    end

    # A run of spaces that occupies exactly as many code units as `string`.
    def blank(string)
      " " * length(string)
    end

    # Character index in `source` for an LSP position. Out-of-range positions
    # are clamped to the end of the line / document rather than raising.
    def offset(source, line, character)
      index = 0
      line.times do
        newline = source.index("\n", index)
        return source.length if newline.nil?

        index = newline + 1
      end

      units = 0
      while units < character
        char = source[index]
        break if char.nil? || char == "\n"

        units += width(char)
        index += 1
      end
      index
    end

    # LSP position of the end of `text`.
    def end_position(text)
      last_newline = text.rindex("\n")
      if last_newline
        { line: text.count("\n"), character: length(text[(last_newline + 1)..]) }
      else
        { line: 0, character: length(text) }
      end
    end
  end
end
