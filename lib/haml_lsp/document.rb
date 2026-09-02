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
      reset_caches
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
      lines[line].to_s.chomp("\r")
    end

    # Length of the template line in code units of the position encoding
    # (0 for lines past the end of the document).
    def line_length(line)
      @line_lengths[line] ||= @encoding.length(line(line))
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
      reset_caches
    end

    def line_count
      @source.count("\n") + 1
    end

    private

    def extractor
      @extractor ||= RubyExtractor.new(@source, encoding: @encoding).tap(&:extract)
    end

    def lines
      @lines ||= @source.split("\n", -1)
    end

    def reset_caches
      @extractor = nil
      @lines = nil
      @line_lengths = {}
    end
  end
end
