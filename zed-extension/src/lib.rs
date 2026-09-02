//! Zed extension that attaches `haml-lsp` to the `Haml` language.
//!
//! Locating the server, in order of preference:
//!
//! 1. `lsp.haml-lsp.binary.path` from Zed settings.
//! 2. `bundle exec haml-lsp` when the worktree's `Gemfile.lock` includes the gem
//!    (disable with `lsp.haml-lsp.settings.use_bundler = false`).
//! 3. `haml-lsp` from the worktree's shell `PATH` (`gem install haml-lsp`).

use zed_extension_api::{
    self as zed, settings::LspSettings, Command, LanguageServerId, Result, Worktree,
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

        Err(format!(
            "{EXECUTABLE} was not found. Install it with `gem install {GEM_NAME}`, add `gem \"{GEM_NAME}\"` \
             to your Gemfile, or set `lsp.{EXECUTABLE}.binary.path` in Zed settings. \
             haml-lsp also needs `ruby-lsp` to be installed."
        ))
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
}

zed::register_extension!(HamlLspExtension);

#[cfg(test)]
mod tests {
    use super::lockfile_lists_gem;

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
}
