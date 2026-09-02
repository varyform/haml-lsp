# frozen_string_literal: true

module HamlLsp
  # Completions for HAML's own syntax, offered where the cursor is *not* inside
  # embedded Ruby: tag names after `%`, filter names after `:`, and doctypes
  # after `!!!`.
  module HamlCompletion
    # LSP CompletionItemKind values.
    KIND_KEYWORD = 14
    KIND_MODULE = 9
    KIND_VALUE = 12

    # Marker so the proxy can recognise its own items in `completionItem/resolve`.
    DATA = { hamlLsp: true }.freeze

    HTML_TAGS = %w[
      a abbr address area article aside audio b base bdi bdo blockquote body br button canvas caption cite code col
      colgroup data datalist dd del details dfn dialog div dl dt em embed fieldset figcaption figure footer form h1 h2
      h3 h4 h5 h6 head header hgroup hr html i iframe img input ins kbd label legend li link main map mark menu meta
      meter nav noscript object ol optgroup option output p param picture pre progress q rp rt ruby s samp script
      search section select slot small source span strong style sub summary sup table tbody td template textarea
      tfoot th thead time title tr track u ul var video wbr
      svg path circle rect line polyline polygon g defs use symbol text
    ].freeze

    FALLBACK_FILTERS = %w[cdata coffee css erb escaped javascript less markdown plain preserve ruby sass scss].freeze

    DOCTYPES = {
      "5" => "<!DOCTYPE html>",
      "XML" => "<?xml version='1.0' encoding='utf-8' ?>",
      "Strict" => "XHTML 1.0 Strict",
      "Frameset" => "XHTML 1.0 Frameset",
      "Mobile" => "XHTML Mobile 1.2",
      "Basic" => "XHTML Basic 1.1",
      "RDFa" => "XHTML+RDFa 1.0",
      "1.1" => "XHTML 1.1",
    }.freeze

    TAG_RE = /\A\s*%([-:\w]*)\z/
    FILTER_RE = /\A\s*:(\w*)\z/
    DOCTYPE_RE = /\A\s*!!!\s+(\S*)\z/

    # Returns a CompletionList (possibly empty) for the given document position.
    def self.items(document, line, character)
      text = document.line(line)
      before = text[0, document.encoding.offset(text, 0, character)].to_s

      items =
        if (match = before.match(TAG_RE))
          tags(match[1], line, character)
        elsif (match = before.match(FILTER_RE))
          filters(match[1], line, character)
        elsif (match = before.match(DOCTYPE_RE))
          doctypes(match[1], line, character)
        else
          []
        end

      { isIncomplete: false, items: items }
    end

    def self.tags(prefix, line, character)
      HTML_TAGS.map do |tag|
        item(tag, KIND_KEYWORD, "HTML tag", prefix, line, character)
      end
    end

    def self.filters(prefix, line, character)
      filter_names.map do |name|
        item(name, KIND_MODULE, "HAML filter", prefix, line, character)
      end
    end

    def self.doctypes(prefix, line, character)
      DOCTYPES.map do |name, description|
        item(name, KIND_VALUE, description, prefix, line, character)
      end
    end

    def self.filter_names
      @filter_names ||=
        if defined?(::Haml::Filters) && (registered = ::Haml::Filters.instance_variable_get(:@registered))
          registered.keys.map(&:to_s).sort
        else
          FALLBACK_FILTERS
        end
    end

    # The edit replaces what the user has typed so far after the sigil, so the
    # editor's own filtering works no matter how the request was triggered.
    def self.item(label, kind, detail, prefix, line, character)
      {
        label: label,
        kind: kind,
        detail: detail,
        filterText: label,
        textEdit: {
          range: {
            start: { line: line, character: character - prefix.length },
            end: { line: line, character: character },
          },
          newText: label,
        },
        data: DATA,
      }
    end
  end
end
