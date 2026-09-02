# haml-lsp

A language server for [HAML](https://haml.info) templates that brings
[ruby-lsp](https://github.com/Shopify/ruby-lsp)'s Ruby intelligence into your
views: hover, go-to-definition, completion, signature help, document
highlights, inlay hints and more — plus HAML syntax diagnostics.

```haml
%section.profile{ class: css_class }
  %h1= @user.full_name            # hover / go-to-definition work here
  - if @user.admin?
    %p= greeting_for(@user)       # ...and here
  = user.la|                      # completion: last_name
```

Ships with a [Zed](https://zed.dev) extension (see [`zed-extension/`](zed-extension)),
but it is a plain stdio LSP server and works with any editor.

## How it works

ruby-lsp only knows Ruby, RBS and ERB documents, and its ERB support works
through a neat trick: every non-Ruby character of the template is replaced
with a space, producing a Ruby "shadow" that has exactly the same line/column
layout. Positions never need to be translated.

haml-lsp does the same for HAML, which is harder because HAML is
indentation-based and embeds Ruby in many different forms. `HamlLsp::RubyExtractor`
turns this:

```haml
%ul.items{ class: klass }
  - items.each do |item|
    %li= link_to item.name, item
  %p Total: #{items.size}
```

into this shadow (`·` = space):

```ruby
·········{ class: klass }
··· items.each do |item|
·······; link_to item.name, item; end
·············items.size;
```

Everything the shadow needs that the template doesn't have — the `end`
closing each block — is appended *past* the end of a line, so no column ever
shifts. haml-lsp then runs as a proxy in front of a ruby-lsp process:

```
editor ──LSP──▶ haml-lsp ──LSP──▶ ruby-lsp
                 │  .haml text kept here; shadow sent on as a Ruby document
                 │  hover/definition/completion/... forwarded verbatim
                 │  formatting/code actions/RuboCop answered locally (empty)
                 └─ HAML syntax diagnostics from Haml::Parser
```

Handled HAML constructs: `- silent` and `= != &= ~ output` scripts, inline tag
scripts (`%p= foo`), attribute hashes `{}` (including multi-line), HTML-style
attributes `()`, object references `[]`, `#{}` interpolation in plain text and
`==` lines, `:ruby` filters (verbatim) and other filters (interpolation only),
`-#` comments, `|` and trailing-comma multiline, mid-block keywords
(`else`/`elsif`/`when`/`in`/`rescue`/`ensure`), doctype, `\` escapes, tabs
and CRLF line endings. Widths are computed in the negotiated LSP position
encoding (utf-8/utf-16/utf-32), so non-ASCII text stays aligned.

## Installation

```sh
gem install haml-lsp ruby-lsp
```

or add it to your project's Gemfile (development group):

```ruby
gem "haml-lsp", require: false
```

haml-lsp starts ruby-lsp itself. By default it runs `bundle exec ruby-lsp`
when the current `Gemfile.lock` contains ruby-lsp and plain `ruby-lsp`
otherwise. Override with `--ruby-lsp-command`, the `HAML_LSP_RUBY_LSP_COMMAND`
environment variable, or the `rubyLspCommand` initialization option.

### Zed

1. Install the **Haml** extension (grammar + highlighting) from the extension
   store.
2. Install the extension in [`zed-extension/`](zed-extension) — until it is
   published: `zed: install dev extension` and pick that directory. Zed
   compiles it with your Rust toolchain, which must be `rustup`-managed so the
   `wasm32-wasip2` target can be added (Homebrew's `rust` formula is not;
   use `brew install rustup` instead).
3. Make sure `haml-lsp` is on the `PATH` of the Ruby that Zed sees (see
   above; with a version manager such as mise/rbenv/asdf, install it into the
   Ruby that is active in your login shell). The extension looks for it in
   your Gemfile.lock (`bundle exec haml-lsp`), then on your `PATH`.
4. Check that nothing in your settings excludes it. If you have a `"Haml"`
   entry under `languages` with a `language_servers` list, that list is
   exclusive and must include `"haml-lsp"`:

   ```jsonc
   "languages": {
     "Haml": {
       "language_servers": ["haml-lsp", "stimulus-lsp"]
     }
   }
   ```

5. Open a `.haml` file. `debug: open language server logs` → `haml-lsp` shows
   both haml-lsp's and the child ruby-lsp's output; the first start in a
   project can take a while because ruby-lsp composes its bundle and indexes
   the code.

Settings (`settings.json`):

```jsonc
{
  "lsp": {
    "haml-lsp": {
      // Run a specific executable, e.g. a git checkout while developing haml-lsp itself:
      // "binary": { "path": "/path/to/haml-lsp/exe/haml-lsp" },
      // "settings": { "use_bundler": false },
      "initialization_options": {
        // passed to haml-lsp; everything except rubyLspCommand is handed to ruby-lsp
        // "rubyLspCommand": ["bundle", "exec", "ruby-lsp"],
        // "enabledFeatures": { "inlayHint": false }
      }
    }
  }
}
```

Until the gem is published, install it from a checkout:

```sh
gem build haml-lsp.gemspec && gem install --local haml-lsp-0.1.0.gem
```

This installs a snapshot — reinstall after changing `lib/`, or point
`lsp.haml-lsp.binary.path` at `exe/haml-lsp` in the checkout instead.

### Other editors

Run `haml-lsp` for the `haml` language id. It speaks LSP over stdio.

## Debugging

Print the Ruby shadow for a template:

```sh
haml-lsp --extract app/views/users/show.html.haml
```

Set `HAML_LSP_DEBUG=1` to log every relayed message to stderr (Zed shows
server stderr in the LSP logs).

## Development

```sh
bundle install
bundle exec rake test     # unit tests (fast; uses a fake ruby-lsp)
ruby bin/smoke            # end-to-end against a real ruby-lsp
cd zed-extension && cargo test
```

## Limitations and notes

- ruby-lsp runs once per haml-lsp instance, in addition to the ruby-lsp your
  editor runs for `.rb` files, so a workspace is indexed twice. A future
  option is to ship haml-lsp as a ruby-lsp add-on so a single process serves
  both.
- Receiver-less helper calls (`= greeting_for(user)`) resolve only when
  ruby-lsp can guess a receiver — the same limitation ERB templates have.
- Formatting, code actions and RuboCop diagnostics are intentionally disabled
  for HAML documents. haml-lint integration would be a natural next step.
- The extractor mirrors the HAML parser's rules but is deliberately tolerant
  of half-typed input; the real `Haml::Parser` is used for diagnostics.

## License

MIT
