# frozen_string_literal: true

module HamlLsp
  # `textDocument/documentSymbol` for HAML: an outline of tags (with their
  # class/id shorthand) and filters, nested by indentation.
  #
  # ruby-lsp has nothing to say here (the shadow declares nothing), and editors
  # that build their outline from LSP symbols would otherwise show an empty
  # panel. Editors with a tree-sitter outline (Zed) do not use this.
  module DocumentSymbols
    KIND_FIELD = 8   # tags, as HTML language servers do
    KIND_MODULE = 9  # filters

    TAG_RE = /\A(?:%[-:\w]+|\.[-:\w]+|#(?!\{)[-:\w]+)(?:\.[-:\w]+|#[-:\w]+)*/
    FILTER_RE = /\A:\w+/

    def self.for(document)
      Builder.new(document).build
    end

    class Builder
      def initialize(document)
        @document = document
        @root = []
        @stack = [] # [indent, symbol]
        @last_content_line = 0
      end

      def build
        @document.source.split("\n", -1).each_with_index do |raw, index|
          line = raw.chomp("\r")
          next if line.strip.empty?

          indent = line[/\A[ \t]*/].length
          close_symbols(indent)
          @last_content_line = index

          content = line[indent..]
          name, kind = name_and_kind(content)
          next unless name

          symbol = {
            name: name,
            kind: kind,
            range: { start: { line: index, character: 0 }, end: nil },
            selectionRange: {
              start: { line: index, character: indent },
              end: { line: index, character: indent + @document.encoding.length(name) },
            },
            children: [],
          }

          (@stack.last&.last&.dig(:children) || @root) << symbol
          @stack << [indent, symbol]
        end

        close_symbols(-1)
        @root
      end

      private

      def name_and_kind(content)
        if (match = content.match(TAG_RE))
          [match[0], KIND_FIELD]
        elsif (match = content.match(FILTER_RE))
          [match[0], KIND_MODULE]
        end
      end

      # A symbol ends on the last content line before the first line that is
      # not indented deeper than it.
      def close_symbols(indent)
        while (top = @stack.last) && top.first >= indent
          _, symbol = @stack.pop
          symbol[:range][:end] = {
            line: @last_content_line,
            character: @document.line_length(@last_content_line),
          }
        end
      end
    end
  end
end
