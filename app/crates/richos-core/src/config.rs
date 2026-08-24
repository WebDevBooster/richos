//! Durable CEO-facing configuration — company identity + the assertiveness dial.
//!
//! Persisted to a small JSON file, deliberately SEPARATE from the ledger's append-only
//! event log (this is mutable point-in-time state, not an event stream) but stored
//! "alongside the ledger's storage" per the task brief — i.e. in the same app data dir,
//! same durability posture (survives restart), same file-based substrate.
//!
//! Two seams live here:
//!   - `company_name` — the UX direction doc §2.1: "Rail header = the company/CEO identity,
//!     not RichOS." Configurable, persisted, sensible fallback when unset (§4.4/P4
//!     provisioning is the eventual "create your company" flow; this is the plumbing
//!     it will write into, wired ahead of that UI existing).
//!   - `assertiveness` — UX doc §5.2: one plain 3-way dial ("How much should Rich
//!     interrupt you?" Quiet / Balanced / Only when it's urgent). Default = Quiet
//!     (per the CEO decision: the acceptable failure mode is "too quiet," never
//!     "annoying"). Survives restart.

use serde::{Deserialize, Serialize};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// The CEO's proactive-attention dial (UX doc §5.2). Values match the radio inputs in
/// `app/ui/index.html` (`name="assertiveness"`) verbatim, so the wire string never needs
/// translating on the UI side.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Assertiveness {
    Quiet,
    Balanced,
    UrgentOnly,
}

impl Default for Assertiveness {
    /// Default = Quiet. Per the CEO decision: model an excellent human chief of staff;
    /// the failure mode is "too quiet," NEVER "annoying."
    fn default() -> Self {
        Assertiveness::Quiet
    }
}

impl Assertiveness {
    pub fn as_str(&self) -> &'static str {
        match self {
            Assertiveness::Quiet => "quiet",
            Assertiveness::Balanced => "balanced",
            Assertiveness::UrgentOnly => "urgent-only",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "quiet" => Some(Assertiveness::Quiet),
            "balanced" => Some(Assertiveness::Balanced),
            "urgent-only" => Some(Assertiveness::UrgentOnly),
            _ => None,
        }
    }
}

/// The sensible fallback shown when no company name has been configured yet — matches
/// the UI's own placeholder constant (`app/ui/main.js` `COMPANY_LABEL_FALLBACK`) so the
/// two sides can never drift into showing two different defaults.
pub const COMPANY_NAME_FALLBACK: &str = "My Company";

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct StoredConfig {
    company_name: Option<String>,
    #[serde(default)]
    assertiveness: Assertiveness,
}

/// A small JSON-file-backed config store. Read once at open, written eagerly (whole-file
/// rewrite) on every set — the file is tiny, so this stays simple and crash-safe-enough
/// (a torn write here loses at most the CEO's last preference toggle, not a message).
pub struct ConfigStore {
    path: PathBuf,
    config: StoredConfig,
}

impl ConfigStore {
    /// Open (or initialize with defaults if absent/corrupt) the config file at `path`.
    /// A corrupt file degrades to defaults rather than failing the app boot — config is
    /// a preference layer, never a reason "talk to Rich" can't start.
    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref().to_path_buf();
        let config = fs::read_to_string(&path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        Ok(ConfigStore { path, config })
    }

    /// The configured company name, or `None` if never set.
    pub fn company_name(&self) -> Option<&str> {
        self.config.company_name.as_deref()
    }

    /// The configured company name, falling back to `COMPANY_NAME_FALLBACK` when unset —
    /// what the Tauri command actually returns, so the UI never has to know the fallback.
    pub fn company_name_or_default(&self) -> String {
        self.config
            .company_name
            .clone()
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(|| COMPANY_NAME_FALLBACK.to_string())
    }

    pub fn set_company_name(&mut self, name: &str) -> io::Result<()> {
        let trimmed = name.trim();
        self.config.company_name = if trimmed.is_empty() { None } else { Some(trimmed.to_string()) };
        self.persist()
    }

    pub fn assertiveness(&self) -> Assertiveness {
        self.config.assertiveness
    }

    pub fn set_assertiveness(&mut self, level: Assertiveness) -> io::Result<()> {
        self.config.assertiveness = level;
        self.persist()
    }

    fn persist(&self) -> io::Result<()> {
        if let Some(dir) = self.path.parent() {
            fs::create_dir_all(dir)?;
        }
        let serialized = serde_json::to_string_pretty(&self.config)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        fs::write(&self.path, serialized)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_path(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!("richos-config-test-{tag}-{}-{}.json", std::process::id(), crate::util::now_millis()))
    }

    #[test]
    fn default_assertiveness_is_quiet() {
        // Independently confirm the enum default AND the on-disk-absent default agree —
        // both are load-bearing ("the CEO's dial survives restart, default = quiet").
        assert_eq!(Assertiveness::default(), Assertiveness::Quiet);
        let path = tmp_path("default");
        let store = ConfigStore::open(&path).unwrap();
        assert_eq!(store.assertiveness(), Assertiveness::Quiet);
        assert_eq!(store.assertiveness().as_str(), "quiet");
    }

    #[test]
    fn company_name_unset_falls_back_honestly() {
        let path = tmp_path("company-fallback");
        let store = ConfigStore::open(&path).unwrap();
        assert_eq!(store.company_name(), None);
        assert_eq!(store.company_name_or_default(), COMPANY_NAME_FALLBACK);
    }

    #[test]
    fn company_name_and_assertiveness_survive_restart() {
        let path = tmp_path("restart");
        {
            let mut store = ConfigStore::open(&path).unwrap();
            store.set_company_name("Acme Robotics").unwrap();
            store.set_assertiveness(Assertiveness::Balanced).unwrap();
        }
        let reopened = ConfigStore::open(&path).unwrap();
        assert_eq!(reopened.company_name(), Some("Acme Robotics"));
        assert_eq!(reopened.company_name_or_default(), "Acme Robotics");
        assert_eq!(reopened.assertiveness(), Assertiveness::Balanced);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn blank_company_name_clears_to_fallback() {
        let path = tmp_path("blank");
        let mut store = ConfigStore::open(&path).unwrap();
        store.set_company_name("Acme").unwrap();
        store.set_company_name("   ").unwrap();
        assert_eq!(store.company_name(), None);
        assert_eq!(store.company_name_or_default(), COMPANY_NAME_FALLBACK);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn assertiveness_wire_strings_match_the_ui_radio_values() {
        // app/ui/index.html: value="quiet" | "balanced" | "urgent-only" — verbatim.
        assert_eq!(Assertiveness::parse("quiet"), Some(Assertiveness::Quiet));
        assert_eq!(Assertiveness::parse("balanced"), Some(Assertiveness::Balanced));
        assert_eq!(Assertiveness::parse("urgent-only"), Some(Assertiveness::UrgentOnly));
        assert_eq!(Assertiveness::parse("bogus"), None);
    }

    #[test]
    fn corrupt_config_file_degrades_to_defaults_not_a_boot_failure() {
        let path = tmp_path("corrupt");
        std::fs::write(&path, "{ not json").unwrap();
        let store = ConfigStore::open(&path).unwrap();
        assert_eq!(store.assertiveness(), Assertiveness::Quiet);
        assert_eq!(store.company_name(), None);
        let _ = std::fs::remove_file(&path);
    }
}
