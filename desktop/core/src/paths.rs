//! Cross-platform discovery of the agents' local data directories.
//!
//! macOS and Linux put everything under the home directory; Windows uses the
//! same dotfolders for DSH/Codex but OpenCode may live under `%LOCALAPPDATA%`.
//! Every path can be overridden through `WgPaths`, which keeps tests and the
//! `wg-dump` diagnostics independent of the real machine.

use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
pub struct WgPaths {
    pub home: PathBuf,
    pub dsh_root: PathBuf,
    pub codex_root: PathBuf,
    pub opencode_data_dir: PathBuf,
    pub opencode_db: PathBuf,
}

impl WgPaths {
    pub fn default_paths() -> Self {
        let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));

        let codex_root = std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"));

        let opencode_data_dir = opencode_candidates(&home)
            .into_iter()
            .find(|dir| dir.join("opencode.db").exists())
            .unwrap_or_else(|| default_opencode_dir(&home));

        Self {
            dsh_root: home.join(".dsh"),
            codex_root,
            opencode_db: opencode_data_dir.join("opencode.db"),
            opencode_data_dir,
            home,
        }
    }

    pub fn dsh_sessions(&self) -> PathBuf {
        self.dsh_root.join("sessions")
    }

    pub fn dsh_workspace_json(&self) -> PathBuf {
        self.dsh_root.join("storages").join("workspace.json")
    }

    pub fn dsh_cost_ledger(&self) -> PathBuf {
        self.dsh_root
            .join("storages")
            .join("cost-meter")
            .join("ledger.json")
    }

    pub fn codex_sessions(&self) -> PathBuf {
        self.codex_root.join("sessions")
    }

    pub fn opencode_log(&self) -> PathBuf {
        self.opencode_data_dir.join("log").join("opencode.log")
    }

    /// The DSH plugin reads this to know whether the pet is running/visible.
    pub fn dsh_pet_state(&self) -> PathBuf {
        self.dsh_root.join("storages").join("bluefish-pet.json")
    }

    pub fn with_home(home: impl AsRef<Path>) -> Self {
        let home = home.as_ref().to_path_buf();
        let opencode_data_dir = home.join(".local").join("share").join("opencode");
        Self {
            dsh_root: home.join(".dsh"),
            codex_root: home.join(".codex"),
            opencode_db: opencode_data_dir.join("opencode.db"),
            opencode_data_dir,
            home,
        }
    }
}

fn default_opencode_dir(home: &Path) -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            return PathBuf::from(local).join("opencode");
        }
    }
    home.join(".local").join("share").join("opencode")
}

fn opencode_candidates(home: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(xdg) = std::env::var_os("XDG_DATA_HOME") {
        out.push(PathBuf::from(xdg).join("opencode"));
    }
    #[cfg(target_os = "windows")]
    {
        if let Some(local) = std::env::var_os("LOCALAPPDATA") {
            out.push(PathBuf::from(local).join("opencode"));
        }
        if let Some(roaming) = std::env::var_os("APPDATA") {
            out.push(PathBuf::from(roaming).join("opencode"));
        }
        out.push(home.join("AppData").join("Local").join("opencode"));
    }
    out.push(home.join(".local").join("share").join("opencode"));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derived_paths_stay_under_home() {
        let paths = WgPaths::with_home("/tmp/wg-home");
        assert!(paths.dsh_sessions().starts_with("/tmp/wg-home"));
        assert!(paths.codex_sessions().starts_with("/tmp/wg-home"));
    }
}
