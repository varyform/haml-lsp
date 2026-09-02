//! Zed extension that attaches `haml-lsp` to the `Haml` language.
//!
//! Locating the server, in order of preference:
//!
//! 1. `lsp.haml-lsp.binary.path` from Zed settings.
//! 2. `bundle exec haml-lsp` when the worktree's `Gemfile.lock` includes the gem
//!    (disable with `lsp.haml-lsp.settings.use_bundler = false`).
//! 3. `haml-lsp` from the worktree's shell `PATH` (`gem install haml-lsp`).
//! 4. Otherwise the gem is installed automatically into an extension-managed
//!    gem directory (see `gemset.rs`), together with `ruby-lsp` when that is
//!    not available through Bundler or `PATH` either. Disable with
//!    `lsp.haml-lsp.settings.auto_install = false`.

mod gemset;

use gemset::Gemset;
use zed_extension_api::{
    self as zed, lsp::CompletionKind, lsp::SymbolKind, settings::LspSettings, CodeLabel,
    CodeLabelSpan, Command, LanguageServerId, LanguageServerInstallationStatus, Result, Worktree,
};

const EXECUTABLE: &str = "haml-lsp";
const GEM_NAME: &str = "haml-lsp";
const RUBY_LSP: &str = "ruby-lsp";

struct HamlLspExtension;

impl HamlLspExtension {
    fn gemfile_lock_has_gem(worktree: &Worktree, gem: &str) -> bool {
        worktree
            .read_text_file("Gemfile.lock")
            .map(|lock| lockfile_lists_gem(&lock, gem))
            .unwrap_or(false)
    }

    fn gemset(env: &[(String, String)]) -> Result<Gemset> {
        let base_dir = std::env::current_dir()
            .map_err(|e| format!("failed to locate the extension directory: {e}"))?;
        Gemset::for_ruby(&base_dir, env)
    }

    /// haml-lsp finds `ruby-lsp` itself through the project's Gemfile.lock or
    /// `PATH`. When neither has it (typical for people relying on the Ruby
    /// extension's own private install), provide one from our gem directory
    /// and point haml-lsp at it. Returns the extra arguments and environment.
    fn ruby_lsp_fallback(
        language_server_id: &LanguageServerId,
        worktree: &Worktree,
        env: Vec<(String, String)>,
        auto_install: bool,
    ) -> Result<(Vec<String>, Vec<(String, String)>)> {
        let has_ruby_lsp =
            worktree.which(RUBY_LSP).is_some() || Self::gemfile_lock_has_gem(worktree, RUBY_LSP);
        if has_ruby_lsp || !auto_install {
            return Ok((Vec::new(), env));
        }

        let gemset = Self::gemset(&env)?;
        Self::ensure_installed(&gemset, language_server_id, RUBY_LSP)?;
        Ok((
            vec!["--ruby-lsp-command".to_string(), gemset.bin_path(RUBY_LSP)],
            gemset.env(),
        ))
    }

    /// Installs (or updates) `haml-lsp` in the extension's gem directory and
    /// returns the command to run it from there.
    fn gemset_command(
        language_server_id: &LanguageServerId,
        worktree: &Worktree,
        env: &[(String, String)],
    ) -> Result<Command> {
        let gemset = Self::gemset(env)?;
        Self::ensure_installed(&gemset, language_server_id, GEM_NAME)?;
        let (args, env) = Self::ruby_lsp_fallback(language_server_id, worktree, gemset.env(), true)?;

        Ok(Command {
            command: gemset.bin_path(EXECUTABLE),
            args,
            env,
        })
    }

    fn ensure_installed(gemset: &Gemset, id: &LanguageServerId, gem: &str) -> Result<()> {
        zed::set_language_server_installation_status(
            id,
            &LanguageServerInstallationStatus::CheckingForUpdate,
        );

        match gemset.installed_version(gem)? {
            None => {
                zed::set_language_server_installation_status(
                    id,
                    &LanguageServerInstallationStatus::Downloading,
                );
                gemset.install(gem)
            }
            // Updating is best effort: being offline must not prevent start-up.
            Some(_) => match gemset.is_outdated(gem) {
                Ok(true) => {
                    zed::set_language_server_installation_status(
                        id,
                        &LanguageServerInstallationStatus::Downloading,
                    );
                    if let Err(e) = gemset.update(gem) {
                        eprintln!("haml-lsp: could not update {gem}: {e}");
                    }
                    Ok(())
                }
                Ok(false) => Ok(()),
                Err(e) => {
                    eprintln!("haml-lsp: could not check whether {gem} is outdated: {e}");
                    Ok(())
                }
            },
        }
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

        let setting = |name: &str, default: bool| {
            settings
                .settings
                .as_ref()
                .and_then(|s| s.get(name))
                .and_then(|v| v.as_bool())
                .unwrap_or(default)
        };
        let use_bundler = setting("use_bundler", true);
        let auto_install = setting("auto_install", true);

        let command = if use_bundler && Self::gemfile_lock_has_gem(worktree, GEM_NAME) {
            let bundle = worktree
                .which("bundle")
                .ok_or_else(|| "haml-lsp is in your Gemfile.lock but `bundle` was not found on PATH".to_string())?;
            let (extra_args, env) =
                Self::ruby_lsp_fallback(language_server_id, worktree, env, auto_install)?;
            Command {
                command: bundle,
                args: ["exec".to_string(), EXECUTABLE.to_string()]
                    .into_iter()
                    .chain(extra_args)
                    .collect(),
                env,
            }
        } else if let Some(path) = worktree.which(EXECUTABLE) {
            let (args, env) =
                Self::ruby_lsp_fallback(language_server_id, worktree, env, auto_install)?;
            Command {
                command: path,
                args,
                env,
            }
        } else if auto_install {
            Self::gemset_command(language_server_id, worktree, &env)
                .map_err(|e| format!("{e}\n\n{}", not_found_message(worktree, &env)))?
        } else {
            return Err(not_found_message(worktree, &env));
        };

        zed::set_language_server_installation_status(
            language_server_id,
            &LanguageServerInstallationStatus::None,
        );

        Ok(command)
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
