//! Zed extension that attaches `haml-lsp` to the `Haml` language.
//!
//! Locating the server, in order of preference:
//!
//! 1. `lsp.haml-lsp.binary.path` from Zed settings.
//! 2. `bundle exec haml-lsp` when the worktree's `Gemfile.lock` includes the gem
//!    (disable with `lsp.haml-lsp.settings.use_bundler = false`).
//! 3. `haml-lsp` from the worktree's shell `PATH` (`gem install haml-lsp`).

use zed_extension_api::{
    self as zed, lsp::CompletionKind, lsp::SymbolKind, settings::LspSettings, CodeLabel,
    CodeLabelSpan, Command, LanguageServerId, Result, Worktree,
};

const EXECUTABLE: &str = "haml-lsp";
const GEM_NAME: &str = "haml-lsp";

struct HamlLspExtension;

impl HamlLspExtension {
    fn gemfile_lock_has_gem(worktree: &Worktree) -> bool {
        worktree
            .read_text_file("Gemfile.lock")
            .map(|lock| lockfile_lists_gem(&lock, GEM_NAME))
            .unwrap_or(false)
    }
}

/// Gems appear in the `specs:` section of a lockfile indented by exactly four
/// spaces, e.g. `    haml-lsp (0.1.0)`.
fn lockfile_lists_gem(lockfile: &str, gem: &str) -> bool {
    let prefix = format!("    {gem} (");
    lockfile.lines().any(|line| line.starts_with(&prefix))
}

/// The most common cause of "not found" is a version manager: the gem was
/// installed into one Ruby while Zed's login shell resolves another. Spell
/// out what was searched so the fix is obvious.
fn not_found_message(worktree: &Worktree, env: &[(String, String)]) -> String {
    let ruby = worktree
        .which("ruby")
        .unwrap_or_else(|| "not found".to_string());
    let gem = worktree
        .which("gem")
        .unwrap_or_else(|| "not found".to_string());
    let ruby_lsp = worktree
        .which("ruby-lsp")
        .unwrap_or_else(|| "not found".to_string());
    let path = env
        .iter()
        .find(|(key, _)| key == "PATH")
        .map(|(_, value)| value.as_str())
        .unwrap_or("(empty)");

    format_not_found(&ruby, &gem, &ruby_lsp, path)
}

fn format_not_found(ruby: &str, gem: &str, ruby_lsp: &str, path: &str) -> String {
    format!(
        "`{EXECUTABLE}` was not found.\n\n\
         Zed searched the PATH of your login shell, which resolves to:\n\
         \x20 ruby:     {ruby}\n\
         \x20 gem:      {gem}\n\
         \x20 ruby-lsp: {ruby_lsp}\n\n\
         Fix one of:\n\
         \x20 - run `gem install {GEM_NAME}` with *that* ruby (if you use mise/rbenv/asdf, make sure the \
         global/default Ruby matches the one in your shell)\n\
         \x20 - add `gem \"{GEM_NAME}\"` to your Gemfile and `bundle install`\n\
         \x20 - set `lsp.{EXECUTABLE}.binary.path` in Zed settings\n\n\
         haml-lsp also needs `ruby-lsp` (from PATH or your Gemfile).\n\
         PATH: {path}"
    )
}

impl zed::Extension for HamlLspExtension {
    fn new() -> Self {
        Self
    }

    fn language_server_command(
        &mut self,
        language_server_id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<Command> {
        let settings = LspSettings::for_worktree(language_server_id.as_ref(), worktree)?;
        let env = worktree.shell_env();

        if let Some(path) = settings.binary.as_ref().and_then(|b| b.path.clone()) {
            let args = settings
                .binary
                .as_ref()
                .and_then(|b| b.arguments.clone())
                .unwrap_or_default();
            return Ok(Command {
                command: path,
                args,
                env,
            });
        }

        let use_bundler = settings
            .settings
            .as_ref()
            .and_then(|s| s.get("use_bundler"))
            .and_then(|v| v.as_bool())
            .unwrap_or(true);

        if use_bundler && Self::gemfile_lock_has_gem(worktree) {
            if let Some(bundle) = worktree.which("bundle") {
                return Ok(Command {
                    command: bundle,
                    args: vec!["exec".into(), EXECUTABLE.into()],
                    env,
                });
            }
        }

        if let Some(path) = worktree.which(EXECUTABLE) {
            return Ok(Command {
                command: path,
                args: Vec::new(),
                env,
            });
        }

        Err(not_found_message(worktree, &env))
    }

    fn language_server_initialization_options(
        &mut self,
        language_server_id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<Option<zed::serde_json::Value>> {
        Ok(
            LspSettings::for_worktree(language_server_id.as_ref(), worktree)
                .ok()
                .and_then(|settings| settings.initialization_options),
        )
    }

    /// Syntax-highlights completion entries by kind. Ruby items come from
    /// ruby-lsp (same mapping the Ruby extension uses); HAML items are the tag,
    /// filter and doctype completions haml-lsp adds itself.
    fn label_for_completion(
        &self,
        _language_server_id: &LanguageServerId,
        completion: zed::lsp::Completion,
    ) -> Option<CodeLabel> {
        let zed::lsp::Completion {
            label,
            kind,
            detail,
            label_details,
            ..
        } = completion;
        let kind = kind?;

        let scope = match (kind, detail.as_deref()) {
            (CompletionKind::Keyword, Some("HTML tag")) => "tag",
            (CompletionKind::Module, Some("HAML filter")) => "keyword",
            (CompletionKind::Value, _) => "constant",
            (CompletionKind::Class | CompletionKind::Module, _) => "type",
            (CompletionKind::Constant, _) if label == "nil" => "constant.builtin",
            (CompletionKind::Constant, _) if label.starts_with("__") && label.ends_with("__") => {
                "constant.builtin"
            }
            (CompletionKind::Constant, _) => "constant",
            (
                CompletionKind::Method
                | CompletionKind::Reference
                | CompletionKind::Function
                | CompletionKind::Constructor,
                _,
            ) => "function.method",
            (CompletionKind::Keyword, _) => "keyword",
            (CompletionKind::Field, _) if label.starts_with('@') => "variable.special",
            (CompletionKind::Field, _) if label == "self" || label == "super" => "variable.special",
            (CompletionKind::Variable, _) => "variable",
            (CompletionKind::Property, _) => "property",
            _ => return None,
        };

        let label_len = label.len();
        let mut spans = vec![CodeLabelSpan::literal(label, Some(scope.to_string()))];

        if let Some(label_details) = label_details {
            if let Some(detail) = label_details.detail {
                spans.push(CodeLabelSpan::literal(detail, None));
            }
            if let Some(description) = label_details.description {
                spans.push(CodeLabelSpan::literal(" ", None));
                spans.push(CodeLabelSpan::literal(description, None));
            }
        } else if let Some(detail) = detail {
            spans.push(CodeLabelSpan::literal(" ", None));
            spans.push(CodeLabelSpan::literal(detail, None));
        }

        Some(CodeLabel {
            code: String::new(),
            spans,
            filter_range: (0..label_len).into(),
        })
    }

    fn label_for_symbol(
        &self,
        _language_server_id: &LanguageServerId,
        symbol: zed::lsp::Symbol,
    ) -> Option<CodeLabel> {
        let name = &symbol.name;

        let (code, display_start) = match symbol.kind {
            SymbolKind::Method => (format!("def {name}; end"), 4),
            SymbolKind::Class | SymbolKind::Module => (format!("class {name}; end"), 6),
            SymbolKind::Constant => (name.clone(), 0),
            _ => return None,
        };

        Some(CodeLabel {
            code,
            spans: vec![CodeLabelSpan::code_range(
                display_start..display_start + name.len(),
            )],
            filter_range: (0..name.len()).into(),
        })
    }
}

zed::register_extension!(HamlLspExtension);

#[cfg(test)]
mod tests {
    use super::{format_not_found, lockfile_lists_gem};

    const LOCKFILE: &str = "GEM\n  remote: https://rubygems.org/\n  specs:\n    haml (6.3.0)\n    haml-lsp (0.1.0)\n      haml (>= 6.0)\n    ruby-lsp (0.26.0)\n\nDEPENDENCIES\n  haml-lsp\n";

    #[test]
    fn detects_gem_in_specs() {
        assert!(lockfile_lists_gem(LOCKFILE, "haml-lsp"));
        assert!(lockfile_lists_gem(LOCKFILE, "ruby-lsp"));
    }

    #[test]
    fn ignores_dependencies_section_and_prefixes() {
        assert!(!lockfile_lists_gem(LOCKFILE, "lsp"));
        assert!(!lockfile_lists_gem(
            "DEPENDENCIES\n  haml-lsp\n",
            "haml-lsp"
        ));
    }

    #[test]
    fn not_found_message_names_the_searched_ruby() {
        let message = format_not_found(
            "/opt/rubies/4.0.6/bin/ruby",
            "/opt/rubies/4.0.6/bin/gem",
            "not found",
            "/opt/rubies/4.0.6/bin:/usr/bin",
        );

        assert!(message.contains("`haml-lsp` was not found"));
        assert!(message.contains("ruby:     /opt/rubies/4.0.6/bin/ruby"));
        assert!(message.contains("ruby-lsp: not found"));
        assert!(message.contains("gem install haml-lsp"));
        assert!(message.contains("lsp.haml-lsp.binary.path"));
        assert!(message.ends_with("PATH: /opt/rubies/4.0.6/bin:/usr/bin"));
    }
}
