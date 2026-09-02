# frozen_string_literal: true

begin
  require "haml"
rescue LoadError
  # HAML syntax diagnostics are skipped when the haml gem is unavailable.
end

module HamlLsp
  # Diagnostics for a HAML document: HAML syntax errors from the real HAML
  # parser, and -- when the HAML itself is well formed -- Ruby syntax errors in
  # the embedded code (see RubyDiagnostics). ruby-lsp's own diagnostics
  # (RuboCop, Ruby syntax errors) are intercepted by the proxy because they
  # would lint the shadow's placeholders.
  module Diagnostics
    SEVERITY_ERROR = 1
    SOURCE = "haml"

    def self.available?
      defined?(::Haml::Parser) ? true : false
    end

    def self.for(document)
      haml = haml_errors(document)
      # The shadow of a template with broken indentation is meaningless; report
      # the HAML problem alone.
      return haml unless haml.empty?

      RubyDiagnostics.for(document)
    rescue StandardError
      # A parser blowing up on half-typed input must never take the server down.
      []
    end

    def self.haml_errors(document)
      return [] unless available?

      ::Haml::Parser.new({}).call(document.source)
      []
    rescue ::Haml::SyntaxError => e
      [syntax_error(document, e)]
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
