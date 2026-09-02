# Changelog

All notable changes to haml-lsp and its Zed extension are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and both the gem and the Zed extension follow the same version number.

## [Unreleased]

## [0.3.1] - 2026-09-02

### Fixed

- Ruby diagnostics for end-of-input errors (for example `= @user.`) had a
  zero-width range that editors could not underline. Such ranges now cover
  the character before the line end.

### Added

- `bin/probe`: a scripted editor session against any haml-lsp command that
  prints the negotiated capabilities and the diagnostics for a snippet.

## [0.3.0] - 2026-09-02

### Added

- Ruby syntax errors inside templates are reported as diagnostics (source
  `ruby`): the shadow is parsed with Prism and errors are mapped back onto
  the template. Errors Prism places on blank lines or at end of input are
  attached to the nearest preceding line with Ruby, one diagnostic per line,
  capped at ten. HAML syntax errors take precedence.
- `textDocument/documentSymbol` answers with an outline of tags and filters
  nested by indentation, for editors that build their outline from LSP
  symbols (Zed uses tree-sitter for its outline and is unaffected).
- GitHub Actions CI: minitest suite and gem build on Ruby 3.3/3.4, the
  end-to-end smoke test against ruby-lsp, and fmt/clippy/test/wasm build for
  the Zed extension.

### Changed

- Only the values of HTML-style `(...)` attributes count as Ruby zones; keys
  and parentheses no longer trigger Ruby requests.
- Clients without pull diagnostics receive one `publishDiagnostics` after a
  300 ms quiet period instead of one per keystroke.
- Zed extension: gem directories left over from other Ruby versions are
  removed, and the `gem outdated` network check runs at most once a day per
  gem.

## [0.2.0] - 2026-09-02

### Added

- HAML completions where the cursor is not inside Ruby: HTML tag names after
  `%`, filter names after `:` (taken from the installed `haml` gem), and
  doctypes after `!!!`. `%`, `:` and `!` are completion trigger characters.
- The extractor records which columns of each line are embedded Ruby; hover,
  go-to-definition, signature help and completion in markup or plain text
  are answered locally instead of being forwarded to ruby-lsp.
- Response positions are clamped to the template: ruby-lsp results that point
  at the `end` keywords appended to shadow lines (folding ranges, document
  highlights, semantic tokens) are pulled back inside the real line or
  dropped. Positions in other files are left untouched.
- Zed extension: completion and symbol labels are syntax highlighted by kind,
  including the new HAML items.
- Zed extension: when `haml-lsp` is neither in the project's `Gemfile.lock` nor
  on `PATH`, it is installed automatically into an extension-managed gem
  directory (one per Ruby version). `ruby-lsp` is installed there too whenever
  the project or `PATH` do not provide one, and haml-lsp is pointed at it.
  Opt out with `lsp.haml-lsp.settings.auto_install = false`.
- Zed extension: the "not found" error lists the `ruby`, `gem` and `ruby-lsp`
  resolved from Zed's shell `PATH`, and the `PATH` itself.

### Changed

- Only the changed span of the shadow is sent to ruby-lsp on each edit instead
  of the whole document.
- Delta semantic token requests are no longer advertised (their edits cannot be
  clamped to the template); full and range requests remain.

## [0.1.0] - 2026-09-02

### Added

- `haml-lsp` language server: proxies LSP traffic to a ruby-lsp child process,
  presenting each `.haml` file as a position-preserving Ruby shadow document so
  hover, go-to-definition, completion, signature help, references and other
  Ruby features work inside templates.
- Ruby extraction for silent/output scripts, inline tag scripts, `{}`/`()`/`[]`
  attributes (including multi-line), `#{}` interpolation, `:ruby` and other
  filters, `-#` comments, `|` and trailing-comma multiline, mid-block keywords,
  doctype and escapes, with widths computed in the negotiated position
  encoding.
- HAML syntax diagnostics from `Haml::Parser`.
- Formatting, code actions, on-type formatting and RuboCop diagnostics are
  disabled for HAML documents.
- `haml-lsp --extract FILE` prints the Ruby shadow for debugging.
- Zed extension attaching `haml-lsp` to the `Haml` language, resolving the
  server through `Gemfile.lock` (`bundle exec`) or `PATH`.

[Unreleased]: https://github.com/olehsavchuk/haml-lsp/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/olehsavchuk/haml-lsp/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/olehsavchuk/haml-lsp/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/olehsavchuk/haml-lsp/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/olehsavchuk/haml-lsp/releases/tag/v0.1.0
