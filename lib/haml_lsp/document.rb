# frozen_string_literal: true

module HamlLsp
  # An open HAML document plus its Ruby shadow.
  #
  # The proxy owns the real HAML text: the editor's incremental edits are
  # applied here, and the shadow handed to ruby-lsp is regenerated from
  # scratch (ruby-lsp re-parses the whole document on every change anyway, so
  # there is nothing to gain from incremental shadow updates).
  class Document
    attr_reader :uri, :source, :version, :encoding

    def initialize(uri:, source:, version:, encoding: PositionEncoding.new)
      @uri = uri
      @source = source.dup
      @version = version
      @encoding = encoding
      @ruby = nil
    end

    def ruby
      @ruby ||= RubyExtractor.extract(@source, encoding: @encoding)
    end

    # Applies `textDocument/didChange` content changes (incremental or full).
    def apply_changes(changes, version:)
      changes.each do |change|
        range = change[:range]
        if range
          start_offset = @encoding.offset(@source, range[:start][:line], range[:start][:character])
          end_offset = @encoding.offset(@source, range[:end][:line], range[:end][:character])
          @source[start_offset...end_offset] = change[:text]
        else
          @source = change[:text].dup
        end
      end

      @version = version
      @ruby = nil
    end

    # LSP position of the end of the current shadow, used to build the
    # whole-document replacement edit sent to ruby-lsp.
    def ruby_end_position
      @encoding.end_position(ruby)
    end

    def line_count
      @source.count("\n") + 1
    end
  end
end
