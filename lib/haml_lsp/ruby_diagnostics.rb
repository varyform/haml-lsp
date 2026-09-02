# frozen_string_literal: true

require "prism"

module HamlLsp
  # Syntax errors in the Ruby embedded in a template, found by parsing the
  # shadow with Prism.
  #
  # ruby-lsp's own diagnostics are not used because they would also lint the
  # shadow's placeholders. Here every error is mapped back onto the template
  # with two rules:
  #
  #   * an error located inside a Ruby zone is reported where it is;
  #   * an error located anywhere else (a blank shadow line, appended `end`
  #     text, end of input) is the tail of an unfinished construct, so it is
  #     re-anchored to the nearest preceding line that has Ruby -- which is
  #     where the user needs to look.
  #
  # Prism reports cascades of errors for a single mistake; only the first
  # error per line is kept, genuine in-zone errors win over re-anchored ones,
  # and the total is capped.
  module RubyDiagnostics
    SEVERITY_ERROR = 1
    SOURCE = "ruby"
    MAX_DIAGNOSTICS = 10

    def self.for(document)
      result = Prism.parse(document.ruby, partial_script: true)
      return [] if result.success?

      shadow_lines = document.ruby.split("\n", -1)
      encoding = document.encoding

      candidates = result.errors.filter_map do |error|
        location = error.location
        line = location.start_line - 1
        character = encoding.length(shadow_lines[line].to_s.byteslice(0, location.start_column).to_s)

        if document.ruby_at?(line, character)
          # Zones on script lines extend past the end of the line (into the
          # appended `end` text), so keep the range inside the template.
          limit = document.line_length(line)
          character = [character, limit].min
          stop =
            if location.end_line - 1 == line
              encoding.length(shadow_lines[line].to_s.byteslice(0, location.end_column).to_s)
            else
              limit
            end
          stop = [[stop, character + 1].max, limit].min
          { line: line, range: [character, [stop, character].max], message: error.message, anchored: false }
        elsif (anchor = anchor_line(document, line))
          start, stop = document.ruby_span(anchor)
          { line: anchor, range: [start, stop], message: error.message, anchored: true }
        end
      end

      candidates
        .group_by { |c| c[:line] }
        .sort_by { |line, _| line }
        .first(MAX_DIAGNOSTICS)
        .map do |line, group|
          chosen = group.find { |c| !c[:anchored] } || group.first
          diagnostic(line, chosen)
        end
    end

    # The closest line at or before `line` that has embedded Ruby.
    def self.anchor_line(document, line)
      line = [line, document.line_count - 1].min
      line.downto(0).find { |candidate| document.ruby_span(candidate) }
    end

    def self.diagnostic(line, candidate)
      start, stop = candidate[:range]
      {
        range: {
          start: { line: line, character: start },
          end: { line: line, character: stop },
        },
        severity: SEVERITY_ERROR,
        source: SOURCE,
        message: candidate[:message],
      }
    end
  end
end
