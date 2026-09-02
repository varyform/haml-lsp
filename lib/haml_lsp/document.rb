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
      @extractor = nil
    end

    def ruby
      extractor.ruby
    end

    # Whether the LSP position points into embedded Ruby (as opposed to HAML
    # markup or plain text).
    def ruby_at?(line, character)
      extractor.ruby_at?(line, character)
    end

    # The template line at `line`, without its line terminator.
    def line(line)
      @source.split("\n", -1)[line].to_s.chomp("\r")
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
      @extractor = nil
    end

    def line_count
      @source.count("\n") + 1
    end

    private

    def extractor
      @extractor ||= RubyExtractor.new(@source, encoding: @encoding).tap(&:extract)
    end
  end
end
