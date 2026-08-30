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
//!   - `splash_enabled` — the opening screen's off switch. It lives HERE, beside the
//!     assertiveness dial, because it is the same kind of thing: a durable CEO
//!     preference about how the product behaves toward him, not view state.
//!
//! WHY THE SWITCH IS NOT OPTIONAL, stated where the field is rather than in a design
//! doc nobody reads at the call site: the splash's failure mode is SILENT. Nobody
//! writes in to say a splash screen was beneath them — they switch it off, and if
//! there is nothing to switch, they resent it quietly and we learn nothing
//! (`docs/design/richos-splash-micro-game-2026-08-30.md` §7, richos-hq). So the
//! switch is the instrument, and `splash_first_shown_at` / `splash_disabled_at` are
//! the two timestamps that make §7's primary metric — time-to-disable — actually
//! derivable rather than gestured at. They are MEASUREMENT, never display: §5 of the
//! same document bans every counter, streak and score from the CEO's screen, and
//! nothing reads these two fields back to him.

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

/// The splash's default, as a named function because `#[serde(default)]` on a `bool`
/// means `false` and that is the wrong answer here: a config file written before the
/// splash existed must read as ENABLED, not as "the CEO turned it off". An absent field
/// is an absent OPINION, and the product's opinion is on.
fn splash_default() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredConfig {
    company_name: Option<String>,
    #[serde(default)]
    assertiveness: Assertiveness,
    /// The opening screen's off switch. Default on; an older config file with no such
    /// key reads as on (see `splash_default`).
    #[serde(default = "splash_default")]
    splash_enabled: bool,
    /// When the splash was first shown to this CEO, in epoch millis. Written ONCE, by
    /// the surface itself, and never again — it is the zero point time-to-disable is
    /// measured from.
    #[serde(default)]
    splash_first_shown_at: Option<u64>,
    /// When he last switched it OFF, in epoch millis. Cleared when he switches it back
    /// on, so it never reports a disable that was reversed.
    #[serde(default)]
    splash_disabled_at: Option<u64>,
}

impl Default for StoredConfig {
    fn default() -> Self {
        StoredConfig {
            company_name: None,
            assertiveness: Assertiveness::default(),
            splash_enabled: splash_default(),
            splash_first_shown_at: None,
            splash_disabled_at: None,
        }
    }
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

    // -----------------------------------------------------------------------------------
    // The splash's off switch, and the two timestamps that make it measurable
    // -----------------------------------------------------------------------------------

    /// Whether the opening screen shows at launch. Default on.
    pub fn splash_enabled(&self) -> bool {
        self.config.splash_enabled
    }

    /// Switch the opening screen on or off. Switching OFF stamps `splash_disabled_at`;
    /// switching back ON clears it, because a disable that was reversed is not a disable
    /// and reporting it as one would overstate the only metric this field exists to feed.
    ///
    /// Setting it to the value it already holds is not a change and does not restamp —
    /// otherwise a UI that writes the setting on every launch would keep moving the
    /// timestamp forward and time-to-disable would measure nothing.
    pub fn set_splash_enabled(&mut self, enabled: bool, now_millis: u64) -> io::Result<()> {
        if self.config.splash_enabled == enabled {
            return Ok(());
        }
        self.config.splash_enabled = enabled;
        self.config.splash_disabled_at = if enabled { None } else { Some(now_millis) };
        self.persist()
    }

    /// The first time the splash was shown, epoch millis, or `None` if it never has been.
    pub fn splash_first_shown_at(&self) -> Option<u64> {
        self.config.splash_first_shown_at
    }

    /// When he switched it off, epoch millis, or `None` if it is on (or never was off).
    pub fn splash_disabled_at(&self) -> Option<u64> {
        self.config.splash_disabled_at
    }

    /// Record that the splash has now been shown at least once. Idempotent: the FIRST
    /// call wins and every later one is a no-op that does not even touch the disk, so
    /// the surface can call it on every launch without rewriting the file each time.
    ///
    /// Returns whether it wrote.
    pub fn note_splash_shown(&mut self, now_millis: u64) -> io::Result<bool> {
        if self.config.splash_first_shown_at.is_some() {
            return Ok(false);
        }
        self.config.splash_first_shown_at = Some(now_millis);
        self.persist()?;
        Ok(true)
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
    fn the_splash_is_on_by_default_and_an_absent_key_is_not_an_opinion() {
        // Two different "no value" cases have to give the same answer, and the second is
        // the one a `#[serde(default)]` bool gets wrong: a config file written before the
        // splash existed has no key at all, and reading that as `false` would silently
        // disable a surface for every CEO who already had a config.json.
        let path = tmp_path("splash-default");
        let fresh = ConfigStore::open(&path).unwrap();
        assert!(fresh.splash_enabled(), "a brand-new store shows the splash");
        assert_eq!(fresh.splash_first_shown_at(), None);
        assert_eq!(fresh.splash_disabled_at(), None);

        let older = tmp_path("splash-older-config");
        std::fs::write(&older, r#"{"company_name":"Acme","assertiveness":"balanced"}"#).unwrap();
        let store = ConfigStore::open(&older).unwrap();
        assert!(store.splash_enabled(), "a pre-splash config file reads as ON, not off");
        assert_eq!(store.company_name(), Some("Acme"));
        assert_eq!(store.assertiveness(), Assertiveness::Balanced);
        let _ = std::fs::remove_file(&older);
    }

    #[test]
    fn switching_the_splash_off_survives_restart_and_stamps_when() {
        let path = tmp_path("splash-off");
        {
            let mut store = ConfigStore::open(&path).unwrap();
            store.set_splash_enabled(false, 1_700_000_000_000).unwrap();
        }
        let reopened = ConfigStore::open(&path).unwrap();
        assert!(!reopened.splash_enabled(), "off stays off across a relaunch");
        assert_eq!(reopened.splash_disabled_at(), Some(1_700_000_000_000));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_reversed_disable_is_not_reported_as_a_disable() {
        // Time-to-disable is the whole point of the timestamp. A CEO who switched it off,
        // looked, and switched it back on has NOT disabled the surface, and leaving the
        // stamp behind would count him as though he had.
        let path = tmp_path("splash-reversed");
        let mut store = ConfigStore::open(&path).unwrap();
        store.set_splash_enabled(false, 1_700_000_000_000).unwrap();
        assert_eq!(store.splash_disabled_at(), Some(1_700_000_000_000));
        store.set_splash_enabled(true, 1_700_000_060_000).unwrap();
        assert!(store.splash_enabled());
        assert_eq!(store.splash_disabled_at(), None);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn setting_the_switch_to_what_it_already_is_never_moves_the_clock() {
        // The UI syncs this preference on every launch. If an idempotent write restamped,
        // the disable timestamp would walk forward with every relaunch and measure the
        // last launch rather than the decision.
        let path = tmp_path("splash-idempotent");
        let mut store = ConfigStore::open(&path).unwrap();
        store.set_splash_enabled(false, 1_700_000_000_000).unwrap();
        store.set_splash_enabled(false, 1_799_999_999_999).unwrap();
        assert_eq!(store.splash_disabled_at(), Some(1_700_000_000_000));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn the_first_showing_is_recorded_once_and_only_once() {
        let path = tmp_path("splash-first-shown");
        let mut store = ConfigStore::open(&path).unwrap();
        assert!(store.note_splash_shown(1_700_000_000_000).unwrap(), "the first call writes");
        assert!(!store.note_splash_shown(1_700_000_500_000).unwrap(), "every later call is a no-op");
        assert_eq!(store.splash_first_shown_at(), Some(1_700_000_000_000));

        let reopened = ConfigStore::open(&path).unwrap();
        assert_eq!(reopened.splash_first_shown_at(), Some(1_700_000_000_000));
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn corrupt_config_file_degrades_to_defaults_not_a_boot_failure() {
        let path = tmp_path("corrupt");
        std::fs::write(&path, "{ not json").unwrap();
        let store = ConfigStore::open(&path).unwrap();
        assert_eq!(store.assertiveness(), Assertiveness::Quiet);
        assert_eq!(store.company_name(), None);
        // And the splash degrades to ON, not off — a corrupt preferences file must not be
        // able to silently remove a surface.
        assert!(store.splash_enabled());
        let _ = std::fs::remove_file(&path);
    }
}
