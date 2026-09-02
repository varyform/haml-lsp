# frozen_string_literal: true

module HamlLsp
  # Keeps ruby-lsp responses inside the real template.
  #
  # The shadow has `; end` (and the occasional `,`) appended past the end of
  # some lines. ruby-lsp may legitimately point at that text -- a folding range
  # ending on `end`, a document highlight of the `end` keyword, a semantic
  # token for it -- but those positions do not exist in the HAML document.
  # This walks a response and, for every position that refers to a HAML
  # document we manage, clamps the character to the line's real length.
  # Items whose range collapses to nothing as a result are dropped from
  # arrays, and semantic tokens starting past the end of their line are removed.
  #
  # Positions belonging to other files (definition targets, rename edits in
  # `.rb` files) are left untouched.
  class ResponseClamper
    TOKEN_STRIDE = 5

    # `documents`: uri => Document for every open HAML document.
    # `default_uri`: the document the request was about, used for positions
    # that carry no URI of their own (hover ranges, folding ranges, ...).
    def initialize(documents, default_uri)
      @documents = documents
      @default_uri = default_uri
    end

    def clamp(result)
      walk(result, @documents[@default_uri])
    end

    private

    def walk(value, document)
      case value
      when Hash then walk_hash(value, document)
      when Array
        value.filter_map do |item|
          clamped = walk(item, document)
          clamped unless collapsed?(item, clamped)
        end
      else value
      end
    end

    def walk_hash(hash, document)
      # Location-like objects (and TextDocumentEdits) carry their own URI and
      # switch the document context; a URI we do not manage means "hands off".
      uri = hash[:uri] || hash[:targetUri] || hash.dig(:textDocument, :uri)
      document = document_for(uri) if uri

      if position?(hash)
        document ? clamp_position(hash, document) : hash
      elsif folding_range?(hash)
        document ? clamp_folding_range(hash, document) : hash
      else
        hash.each_with_object({}) do |(key, value), out|
          out[key] =
            if key == :changes && value.is_a?(Hash)
              walk_changes(value)
            elsif key == :data && document && semantic_token_data?(value)
              clamp_tokens(value, document)
            else
              walk(value, document)
            end
        end
      end
    end

    # WorkspaceEdit#changes is keyed by URI.
    def walk_changes(changes)
      changes.each_with_object({}) do |(uri, edits), out|
        out[uri] = walk(edits, document_for(uri))
      end
    end

    def document_for(uri)
      @documents[uri.to_s]
    end

    def position?(hash)
      hash.size == 2 && hash[:line].is_a?(Integer) && hash[:character].is_a?(Integer)
    end

    def folding_range?(hash)
      hash[:startLine].is_a?(Integer) && hash[:endLine].is_a?(Integer)
    end

    def semantic_token_data?(value)
      value.is_a?(Array) && (value.size % TOKEN_STRIDE).zero? && value.all?(Integer)
    end

    def clamp_position(position, document)
      limit = document.line_length(position[:line])
      position[:character] <= limit ? position : { line: position[:line], character: limit }
    end

    def clamp_folding_range(range, document)
      out = range.dup
      if range[:startCharacter].is_a?(Integer)
        out[:startCharacter] = [range[:startCharacter], document.line_length(range[:startLine])].min
      end
      if range[:endCharacter].is_a?(Integer)
        out[:endCharacter] = [range[:endCharacter], document.line_length(range[:endLine])].min
      end
      out
    end

    # An item whose non-empty range became empty pointed entirely at appended text.
    def collapsed?(before, after)
      return false unless before.is_a?(Hash) && after.is_a?(Hash)

      old_range = before[:range]
      new_range = after[:range]
      old_range.is_a?(Hash) && new_range.is_a?(Hash) &&
        old_range[:start] != old_range[:end] && new_range[:start] == new_range[:end]
    end

    # Semantic tokens are delta encoded: [deltaLine, deltaStart, length, type, modifiers].
    def clamp_tokens(data, document)
      line = 0
      start = 0
      kept = []
      last_line = 0
      last_start = 0

      data.each_slice(TOKEN_STRIDE) do |delta_line, delta_start, length, type, modifiers|
        line += delta_line
        start = delta_line.zero? ? start + delta_start : delta_start
        limit = document.line_length(line)
        next if start >= limit

        kept.push(
          line - last_line,
          line == last_line ? start - last_start : start,
          [length, limit - start].min,
          type,
          modifiers,
        )
        last_line = line
        last_start = start
      end

      kept
    end
  end
end
