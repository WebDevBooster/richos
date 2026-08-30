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
//!   - `techy_default` + `techy_threads` — the techy-mode toggle
//!     (`richos-hq/docs/plans/richos-techy-mode-2026-08-26.md` §3.1). Rendering only:
//!     routing and retention run ALWAYS (§3.2), which is the only reason "turn the
//!     technical view on for a conversation I already had" is possible at all.
//!
//! ## Why the toggle is here and not a ledger event (§3.1)
//! It is mutable point-in-time PREFERENCE, which is exactly what this file's first
//! paragraph says the store exists for. A toggle flipped twenty times would otherwise
//! write twenty immutable facts into a log whose job is conversational truth.
//!
//! ## §7.1 IS THE CEO'S QUESTION AND IS NOT ANSWERED HERE
//! *"Global default, or per-thread only?"* is open (open-items 1.4). Both answers are
//! reachable from this shape and neither is baked in: a thread carries `Some(bool)` when
//! the CEO pinned it and `None` when it follows the global default, so "one switch for
//! all of them" and "per-thread only" are the same store read two ways. The clearing
//! setter ([`ConfigStore::clear_techy_thread`]) exists for that reason and for no other —
//! without it a thread could never be handed BACK to the default once pinned, which
//! would quietly settle §7.1 in favour of per-thread.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
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
    /// §3.1: the global default. `false`, so a fresh install's conversation surface is
    /// the calm one and Urban's v1 direction needs no amendment (§3.3).
    #[serde(default)]
    techy_default: bool,
    /// §3.1: per-thread overrides. A thread ABSENT from this map follows
    /// `techy_default`; a thread present pins its own answer. `BTreeMap` so the file
    /// serializes in a stable order and a diff of `config.json` is readable.
    #[serde(default)]
    techy_threads: BTreeMap<String, bool>,
}

/// Where a thread's techy-mode answer came from — reported to the UI so the CEO's own
/// surface can say *"this thread follows your default"* rather than implying he chose it.
///
/// Not decoration: it is what makes clearing an override a visible, reversible act
/// instead of a state the surface cannot distinguish from "he pinned it to the same
/// value the default happens to have".
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TechySource {
    /// The CEO pinned this thread.
    Thread,
    /// No override — the thread follows `techy_default`.
    Default,
}

impl TechySource {
    pub fn as_str(&self) -> &'static str {
        match self {
            TechySource::Thread => "thread",
            TechySource::Default => "default",
        }
    }
}

/// One thread's resolved techy-mode state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TechyMode {
    /// What the renderer should do for this thread, right now.
    pub enabled: bool,
    /// Where `enabled` came from.
    pub source: TechySource,
    /// The global default, carried alongside so a settings surface can show both without
    /// a second round trip.
    pub default: bool,
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

    // ---- techy mode (design §3.1) ------------------------------------------------

    /// The global default. `false` on a fresh install.
    pub fn techy_default(&self) -> bool {
        self.config.techy_default
    }

    /// Set the global default. Threads with no override follow it immediately; threads
    /// the CEO pinned are untouched, which is what makes a pin mean something.
    pub fn set_techy_default(&mut self, enabled: bool) -> io::Result<()> {
        self.config.techy_default = enabled;
        self.persist()
    }

    /// This thread's override, or `None` when it follows the default.
    pub fn techy_thread(&self, thread_id: &str) -> Option<bool> {
        self.config.techy_threads.get(thread_id).copied()
    }

    /// Pin one thread's answer, overriding the default.
    pub fn set_techy_thread(&mut self, thread_id: &str, enabled: bool) -> io::Result<()> {
        self.config.techy_threads.insert(thread_id.to_string(), enabled);
        self.persist()
    }

    /// Hand this thread back to the global default. See the module doc's §7.1 note —
    /// without this a pin would be one-way and the CEO's "all of them" switch would stop
    /// reaching any thread he had ever touched.
    pub fn clear_techy_thread(&mut self, thread_id: &str) -> io::Result<()> {
        self.config.techy_threads.remove(thread_id);
        self.persist()
    }

    /// §2.5 rule 6 / §7.4's shape: forget a thread's preference when the thread goes.
    ///
    /// **This does NOT answer §7.4** (*"does deleting a thread delete its machinery?"*) —
    /// that is the CEO's call and no delete-thread command exists (`main.rs`). This is
    /// only the preference half, so that whoever adds a delete does not leave a pin
    /// pointing at a thread that no longer exists. The journal half is
    /// [`crate::journal::MachineryJournal::delete_thread`], deliberately separate, so
    /// either answer to §7.4 can be assembled from these two without changing either.
    pub fn forget_techy_thread(&mut self, thread_id: &str) -> io::Result<()> {
        self.clear_techy_thread(thread_id)
    }

    /// The resolved answer for one thread: the override if there is one, else the global
    /// default — reported with its provenance so the surface never implies a choice the
    /// CEO did not make.
    pub fn techy_mode(&self, thread_id: &str) -> TechyMode {
        match self.techy_thread(thread_id) {
            Some(enabled) => TechyMode {
                enabled,
                source: TechySource::Thread,
                default: self.config.techy_default,
            },
            None => TechyMode {
                enabled: self.config.techy_default,
                source: TechySource::Default,
                default: self.config.techy_default,
            },
        }
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

    // ---- techy mode (§3.1) --------------------------------------------------------

    #[test]
    fn techy_mode_is_off_on_a_fresh_install_and_says_it_follows_the_default() {
        // §3.3: with techy mode off the conversation surface is byte-identical to today,
        // so the ONLY safe default is off — and a fresh install has no override anywhere,
        // which is a different fact from "he chose off for this thread".
        let path = tmp_path("techy-fresh");
        let store = ConfigStore::open(&path).unwrap();
        assert!(!store.techy_default());
        assert_eq!(store.techy_thread("thr_1"), None);
        let mode = store.techy_mode("thr_1");
        assert!(!mode.enabled);
        assert_eq!(mode.source, TechySource::Default);
        assert_eq!(mode.source.as_str(), "default");
        assert!(!mode.default);
    }

    #[test]
    fn the_global_switch_reaches_every_thread_that_has_not_been_pinned() {
        // §7.1's "all" half, and the CEO's own words: "some OR ALL of their
        // conversations". One switch, not N toggles.
        let path = tmp_path("techy-global");
        let mut store = ConfigStore::open(&path).unwrap();
        store.set_techy_default(true).unwrap();
        for thread in ["thr_a", "thr_b", "thr_never_seen_before"] {
            let mode = store.techy_mode(thread);
            assert!(mode.enabled, "{thread} should follow the global default");
            assert_eq!(mode.source, TechySource::Default);
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_pinned_thread_keeps_its_answer_when_the_global_default_moves_under_it() {
        // §7.1's "some" half. If flipping the global switch silently rewrote the CEO's
        // per-thread choices, "per-thread" would be decoration.
        let path = tmp_path("techy-pin");
        let mut store = ConfigStore::open(&path).unwrap();
        store.set_techy_thread("thr_pinned_off", false).unwrap();
        store.set_techy_thread("thr_pinned_on", true).unwrap();
        store.set_techy_default(true).unwrap();
        assert!(!store.techy_mode("thr_pinned_off").enabled, "the pin survives the switch");
        assert!(store.techy_mode("thr_pinned_on").enabled);
        assert!(store.techy_mode("thr_unpinned").enabled, "and the unpinned one follows it");
        store.set_techy_default(false).unwrap();
        assert!(store.techy_mode("thr_pinned_on").enabled, "in both directions");
        assert!(!store.techy_mode("thr_unpinned").enabled);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn clearing_an_override_hands_the_thread_back_to_the_default() {
        // The reversibility that keeps §7.1 OPEN. Without it a pin is one-way and the
        // product has quietly chosen "per-thread only".
        let path = tmp_path("techy-clear");
        let mut store = ConfigStore::open(&path).unwrap();
        store.set_techy_default(true).unwrap();
        store.set_techy_thread("thr_1", false).unwrap();
        assert_eq!(store.techy_mode("thr_1").source, TechySource::Thread);
        assert!(!store.techy_mode("thr_1").enabled);

        store.clear_techy_thread("thr_1").unwrap();
        assert_eq!(store.techy_thread("thr_1"), None);
        let mode = store.techy_mode("thr_1");
        assert_eq!(mode.source, TechySource::Default);
        assert!(mode.enabled, "back under the global switch, not stuck at its old value");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn pinning_a_thread_to_the_same_value_as_the_default_is_still_a_pin() {
        // The distinction `TechySource` exists for: "he chose this" and "this is what the
        // default happens to be" are different facts, and only the second one moves when
        // the global switch moves.
        let path = tmp_path("techy-samevalue");
        let mut store = ConfigStore::open(&path).unwrap();
        store.set_techy_thread("thr_1", false).unwrap();
        assert_eq!(store.techy_mode("thr_1").source, TechySource::Thread);
        store.set_techy_default(true).unwrap();
        assert!(!store.techy_mode("thr_1").enabled);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn techy_settings_survive_restart() {
        let path = tmp_path("techy-restart");
        {
            let mut store = ConfigStore::open(&path).unwrap();
            store.set_techy_default(true).unwrap();
            store.set_techy_thread("thr_off", false).unwrap();
        }
        let reopened = ConfigStore::open(&path).unwrap();
        assert!(reopened.techy_default());
        assert_eq!(reopened.techy_thread("thr_off"), Some(false));
        assert!(reopened.techy_mode("thr_other").enabled);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_config_written_before_techy_mode_existed_still_opens() {
        // The file on the CEO's disk today has neither key. `#[serde(default)]` on both is
        // what makes this true, and a missing default attribute would turn a launch into a
        // parse failure that silently degrades every OTHER preference to its default too.
        let path = tmp_path("techy-legacy");
        std::fs::write(&path, r#"{"company_name":"Acme Robotics","assertiveness":"balanced"}"#).unwrap();
        let store = ConfigStore::open(&path).unwrap();
        assert_eq!(store.company_name(), Some("Acme Robotics"));
        assert_eq!(store.assertiveness(), Assertiveness::Balanced);
        assert!(!store.techy_default());
        assert_eq!(store.techy_thread("anything"), None);
        let _ = std::fs::remove_file(&path);
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
