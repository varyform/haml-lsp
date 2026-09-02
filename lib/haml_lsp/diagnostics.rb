# frozen_string_literal: true

begin
  require "haml"
rescue LoadError
  # HAML syntax diagnostics are skipped when the haml gem is unavailable.
end

module HamlLsp
  # HAML syntax diagnostics, produced by running the real HAML parser over the
  # template. ruby-lsp's own diagnostics (RuboCop, Ruby syntax errors) are
  # intercepted by the proxy because they would be meaningless on the shadow.
  module Diagnostics
    SEVERITY_ERROR = 1
    SOURCE = "haml"

    def self.available?
      defined?(::Haml::Parser) ? true : false
    end

    def self.for(document)
      return [] unless available?

      ::Haml::Parser.new({}).call(document.source)
      []
    rescue ::Haml::SyntaxError => e
      [syntax_error(document, e)]
    rescue StandardError
      # The parser blowing up on half-typed input must never take the server down.
      []
    end

    def self.syntax_error(document, error)
      # Haml::SyntaxError#line is a 0-based line index (or nil).
      line = error.line || 0
      line = [[line, 0].max, document.line_count - 1].min
      line_text = document.source.lines[line].to_s.chomp
      indent = line_text[/\A[ \t]*/].length

      {
        range: {
          start: { line: line, character: indent },
          end: { line: line, character: document.encoding.length(line_text) },
        },
        severity: SEVERITY_ERROR,
        source: SOURCE,
        message: error.message,
      }
    end
  end
end
