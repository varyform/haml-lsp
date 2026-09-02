# frozen_string_literal: true

module HamlLsp
  # Computes a single `textDocument/didChange` content change that turns one
  # shadow into the next, so that ruby-lsp only receives the lines that
  # actually changed instead of the whole document on every keystroke.
  #
  # The diff is line based: the common prefix and suffix of lines are kept and
  # the span in between is replaced. Because HAML edits are usually local, and
  # `end` markers only move on the lines around the edit, this covers the
  # realistic cases while staying trivially correct.
  module ShadowDiff
    # Returns a content change hash, or nil when the texts are identical.
    def self.change(old_text, new_text, encoding)
      return nil if old_text == new_text

      old_lines = lines(old_text)
      new_lines = lines(new_text)

      prefix = 0
      max_prefix = [old_lines.size, new_lines.size].min
      prefix += 1 while prefix < max_prefix && old_lines[prefix] == new_lines[prefix]

      suffix = 0
      max_suffix = max_prefix - prefix
      while suffix < max_suffix && old_lines[-1 - suffix] == new_lines[-1 - suffix]
        suffix += 1
      end

      replaced = new_lines[prefix...(new_lines.size - suffix)]

      if suffix.positive?
        # Replace whole lines up to the start of the first unchanged suffix line.
        {
          range: {
            start: { line: prefix, character: 0 },
            end: { line: old_lines.size - suffix, character: 0 },
          },
          text: replaced.map { |line| "#{line}\n" }.join,
        }
      elsif prefix.zero?
        # Everything changed.
        {
          range: {
            start: { line: 0, character: 0 },
            end: { line: old_lines.size - 1, character: encoding.length(old_lines.last) },
          },
          text: replaced.join("\n"),
        }
      else
        # The change runs to the end of the document: replace from the end of
        # the last unchanged line so its newline is part of the edit.
        {
          range: {
            start: { line: prefix - 1, character: encoding.length(old_lines[prefix - 1]) },
            end: { line: old_lines.size - 1, character: encoding.length(old_lines.last) },
          },
          text: replaced.map { |line| "\n#{line}" }.join,
        }
      end
    end

    def self.lines(text)
      result = text.split("\n", -1)
      result.empty? ? [""] : result
    end
  end
end
