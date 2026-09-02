//! An extension-managed gem directory, used when `haml-lsp` cannot be found
//! through Bundler or `PATH`. Gems are installed with the user's own `ruby` /
//! `gem` (so native extensions and Ruby version match) into a `GEM_HOME`
//! under the extension's work directory, one per Ruby version.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};
use zed_extension_api::{self as zed, Result};

/// How often `gem outdated` (a network round trip) is allowed to run.
const UPDATE_CHECK_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);
const UPDATE_CHECK_MARKER: &str = ".haml-lsp-update-check";

pub struct Gemset {
    gem_home: PathBuf,
    shell_env: Vec<(String, String)>,
}

impl Gemset {
    /// `base_dir` is the extension work directory. The gem home is keyed by
    /// the Ruby version so switching Rubies never mixes incompatible gems.
    pub fn for_ruby(base_dir: &Path, shell_env: &[(String, String)]) -> Result<Self> {
        let output = zed::Command::new("ruby")
            .arg("--version")
            .envs(shell_env.iter().cloned())
            .output()
            .map_err(|e| format!("failed to run `ruby --version`: {e}"))?;

        if output.status != Some(0) {
            return Err(format!(
                "`ruby --version` failed: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }

        let version = ruby_version_label(&String::from_utf8_lossy(&output.stdout));
        let gems_dir = base_dir.join("gems");
        let gem_home = gems_dir.join(&version);
        remove_other_gem_homes(&gems_dir, &gem_home);

        Ok(Self {
            gem_home,
            shell_env: shell_env.to_vec(),
        })
    }

    /// Whether enough time has passed since the last `gem outdated` check for
    /// `gem`. Records the check when it returns true.
    pub fn should_check_for_updates(&self, gem: &str) -> bool {
        let marker = self.gem_home.join(format!("{UPDATE_CHECK_MARKER}-{gem}"));
        let recently_checked = std::fs::metadata(&marker)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|modified| SystemTime::now().duration_since(modified).ok())
            .is_some_and(|age| age < UPDATE_CHECK_INTERVAL);

        if recently_checked {
            return false;
        }

        let _ = std::fs::create_dir_all(&self.gem_home);
        let _ = std::fs::write(
            &marker,
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .map(|d| d.as_secs().to_string())
                .unwrap_or_default(),
        );
        true
    }

    pub fn bin_path(&self, executable: &str) -> String {
        self.gem_home
            .join("bin")
            .join(executable)
            .display()
            .to_string()
    }

    /// The shell environment with this gem home made visible to Ruby (for the
    /// bin stubs to activate the gems) and its `bin/` appended to `PATH`.
    pub fn env(&self) -> Vec<(String, String)> {
        gemset_env(&self.gem_home, &self.shell_env)
    }

    pub fn installed_version(&self, gem: &str) -> Result<Option<String>> {
        let output = self.gem(&["list", "--exact", gem])?;
        Ok(parse_gem_list(&output, gem))
    }

    pub fn is_outdated(&self, gem: &str) -> Result<bool> {
        let output = self.gem(&["outdated"])?;
        Ok(output
            .lines()
            .any(|line| line.split_whitespace().next() == Some(gem)))
    }

    pub fn install(&self, gem: &str) -> Result<()> {
        self.gem(&[
            "install",
            "--no-user-install",
            "--no-format-executable",
            "--no-document",
            gem,
        ])
        .map(|_| ())
    }

    pub fn update(&self, gem: &str) -> Result<()> {
        self.gem(&["update", "--no-document", gem]).map(|_| ())
    }

    fn gem(&self, args: &[&str]) -> Result<String> {
        let mut command = zed::Command::new("gem");
        command = command.args(
            std::iter::once(args[0])
                .chain(std::iter::once("--norc"))
                .chain(args[1..].iter().copied()),
        );
        command = command.envs(self.shell_env.iter().cloned());
        command = command.env("GEM_HOME", self.gem_home.display().to_string());

        let output = command
            .output()
            .map_err(|e| format!("failed to run `gem {}`: {e}", args.join(" ")))?;

        match output.status {
            Some(0) => Ok(String::from_utf8_lossy(&output.stdout).into_owned()),
            status => Err(format!(
                "`gem {}` failed (status {status:?}): {}",
                args.join(" "),
                String::from_utf8_lossy(&output.stderr).trim()
            )),
        }
    }
}

/// Gem homes are keyed by Ruby version; after switching Rubies the old one is
/// dead weight (tens of MB with ruby-lsp), so drop everything but the current.
fn remove_other_gem_homes(gems_dir: &Path, current: &Path) {
    let Ok(entries) = std::fs::read_dir(gems_dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path != current && path.is_dir() {
            if let Err(e) = std::fs::remove_dir_all(&path) {
                eprintln!(
                    "haml-lsp: could not remove stale gem directory {}: {e}",
                    path.display()
                );
            }
        }
    }
}

/// `ruby 4.0.6 (2026-07-14 revision 03b6d3f889) [arm64-darwin23]` -> `ruby-4.0.6`.
fn ruby_version_label(version_output: &str) -> String {
    let mut words = version_output.split_whitespace();
    match (words.next(), words.next()) {
        (Some(name), Some(version)) => format!("{name}-{version}"),
        _ => "ruby-unknown".to_string(),
    }
}

/// Parses `gem list --exact NAME` output such as `haml-lsp (0.1.0)` or
/// `prism (default: 1.8.1)`.
fn parse_gem_list(output: &str, gem: &str) -> Option<String> {
    output.lines().find_map(|line| {
        let (name, rest) = line.split_once(' ')?;
        if name != gem {
            return None;
        }
        Some(
            rest.trim()
                .trim_start_matches('(')
                .trim_end_matches(')')
                .to_string(),
        )
    })
}

fn gemset_env(gem_home: &Path, shell_env: &[(String, String)]) -> Vec<(String, String)> {
    let mut env: HashMap<String, String> = shell_env.iter().cloned().collect();
    let gem_home_str = gem_home.display().to_string();
    let bin = gem_home.join("bin").display().to_string();

    env.entry("GEM_PATH".to_string())
        .and_modify(|existing| {
            if !std::env::split_paths(existing).any(|p| p == gem_home) {
                *existing = format!("{gem_home_str}:{existing}");
            }
        })
        .or_insert_with(|| gem_home_str.clone());

    env.entry("PATH".to_string())
        .and_modify(|path| *path = format!("{path}:{bin}"))
        .or_insert(bin);

    let mut env: Vec<_> = env.into_iter().collect();
    env.sort();
    env
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_label_uses_name_and_version() {
        assert_eq!(
            ruby_version_label("ruby 4.0.6 (2026-07-14 revision 03b6d3f889) [arm64-darwin23]\n"),
            "ruby-4.0.6"
        );
        assert_eq!(ruby_version_label("garbage"), "ruby-unknown");
    }

    #[test]
    fn parses_gem_list_output() {
        let output = "\n*** LOCAL GEMS ***\n\nhaml-lsp (0.1.0)\nhaml-lsp-other (9.9.9)\n";
        assert_eq!(
            parse_gem_list(output, "haml-lsp"),
            Some("0.1.0".to_string())
        );
        assert_eq!(
            parse_gem_list("prism (default: 1.8.1)", "prism"),
            Some("default: 1.8.1".to_string())
        );
        assert_eq!(parse_gem_list("other (1.0)", "haml-lsp"), None);
    }

    #[test]
    fn env_prepends_gem_path_and_appends_bin_to_path() {
        let env = gemset_env(
            Path::new("/ext/gems/ruby-4.0.6"),
            &[
                ("PATH".to_string(), "/usr/bin".to_string()),
                ("GEM_PATH".to_string(), "/other".to_string()),
            ],
        );
        let env: HashMap<_, _> = env.into_iter().collect();

        assert_eq!(env["GEM_PATH"], "/ext/gems/ruby-4.0.6:/other");
        assert_eq!(env["PATH"], "/usr/bin:/ext/gems/ruby-4.0.6/bin");
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("haml-lsp-gemset-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn removes_gem_homes_of_other_ruby_versions() {
        let gems = temp_dir("cleanup");
        let current = gems.join("ruby-4.0.6");
        let stale = gems.join("ruby-3.3.0");
        std::fs::create_dir_all(current.join("bin")).unwrap();
        std::fs::create_dir_all(stale.join("bin")).unwrap();
        std::fs::write(gems.join("not-a-dir"), "").unwrap();

        remove_other_gem_homes(&gems, &current);

        assert!(current.join("bin").is_dir());
        assert!(!stale.exists());
        assert!(gems.join("not-a-dir").exists());
        let _ = std::fs::remove_dir_all(&gems);
    }

    #[test]
    fn update_checks_are_rate_limited_per_gem() {
        let gem_home = temp_dir("marker");
        let gemset = Gemset {
            gem_home: gem_home.clone(),
            shell_env: Vec::new(),
        };

        assert!(gemset.should_check_for_updates("haml-lsp"));
        assert!(
            !gemset.should_check_for_updates("haml-lsp"),
            "second check within the interval is skipped"
        );
        assert!(
            gemset.should_check_for_updates("ruby-lsp"),
            "other gems have their own marker"
        );
        let _ = std::fs::remove_dir_all(&gem_home);
    }

    #[test]
    fn env_without_existing_values() {
        let env: HashMap<_, _> = gemset_env(Path::new("/ext/gems/ruby-4.0.6"), &[])
            .into_iter()
            .collect();

        assert_eq!(env["GEM_PATH"], "/ext/gems/ruby-4.0.6");
        assert_eq!(env["PATH"], "/ext/gems/ruby-4.0.6/bin");
    }
}
