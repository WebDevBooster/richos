//! Durable CEO-facing configuration — company identity + the assertiveness dial.
//!
//! Persisted to a small JSON file, deliberately SEPARATE from the ledger's append-only
//! event log (this is mutable point-in-time state, not an event stream) but stored
//! "alongside the ledger's storage" per the task brief — i.e. in the same app data dir,
//! same durability posture (survives restart), same file-based substrate.
//!
//! Four seams live here:
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
//!   - `techy_default` + `techy_threads` — the techy-mode toggle
//!     (`richos-hq/docs/plans/richos-techy-mode-2026-08-26.md` §3.1). Rendering only:
//!     routing and retention run ALWAYS (§3.2), which is the only reason "turn the
//!     technical view on for a conversation I already had" is possible at all.
//!   - `raw_retention` — how long the stored output of that technical view survives
//!     (§7.2). It is here for the same reason as everything above it: a mutable
//!     point-in-time preference about how the product behaves toward him. It was two
//!     `const`s in `journal.rs` until 2026-08-30; see the §7.2 note below.
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
//!
//! ## §7.2 IS ALSO THE CEO'S QUESTION AND IS ALSO NOT ANSWERED HERE
//! *"How long do raw payloads survive?"* is open (open-items 1.4), and this file does not
//! decide it. It removes the reason the question was not neutral: "14 days" was
//! `RAW_RETENTION_DAYS` in `journal.rs` and "forever" was a developer's edit, so the
//! status quo was the only answer that cost nothing. Now every answer costs a click, the
//! shipping default reproduces yesterday's behaviour exactly, and [`RetentionChoice`]
//! carries a `Custom` arm precisely so that a value nobody put on a menu is still a value
//! the store can hold and the surface can report honestly rather than round to the nearest
//! button.

use crate::journal::{RawRetention, RetentionLimit, RAW_MAX_TOTAL_BYTES, RAW_RETENTION_DAYS};
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
    /// §3.1: the global default. `false`, so a fresh install's conversation surface is
    /// the calm one and Urban's v1 direction needs no amendment (§3.3).
    #[serde(default)]
    techy_default: bool,
    /// §3.1: per-thread overrides. A thread ABSENT from this map follows
    /// `techy_default`; a thread present pins its own answer. `BTreeMap` so the file
    /// serializes in a stable order and a diff of `config.json` is readable.
    #[serde(default)]
    techy_threads: BTreeMap<String, bool>,
    /// §7.2: how long the raw output survives. **The absent key is what carries the
    /// shipping default** — `RawRetention::default()` is `RAW_RETENTION_DAYS` /
    /// `RAW_MAX_TOTAL_BYTES`, so every config file already on disk keeps behaving exactly
    /// as it did. A key that is PRESENT and unreadable is a different case and keeps
    /// everything instead (`RawRetention::from_json`).
    #[serde(default)]
    raw_retention: RawRetention,
}

impl Default for StoredConfig {
    fn default() -> Self {
        StoredConfig {
            company_name: None,
            assertiveness: Assertiveness::default(),
            splash_enabled: splash_default(),
            splash_first_shown_at: None,
            splash_disabled_at: None,
            techy_default: false,
            techy_threads: BTreeMap::new(),
            raw_retention: RawRetention::default(),
        }
    }
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

/// THE THREE ANSWERS ON THE MENU, plus the honest fourth.
///
/// §7.2's own options, in his words: *"14 days or 2 GB, whichever binds first"*, or
/// *"forever"* — *"~3-4 GB/year on his own disk and a perfectly reasonable choice, it is
/// his machine"*. Those are the two ends; `ThreeMonths` is the middle one, because a dial
/// whose only positions are a fortnight and eternity is not a dial.
///
/// **WHY THE MENU IS THREE NAMES AND NOT TWO NUMBER FIELDS.** The setting has two axes —
/// days and bytes — and asking a CEO to reason about "90 days OR 2 GB, whichever binds
/// first" is asking him to hold the implementation in his head to predict what he will
/// still be able to look at. A named choice hides the arithmetic and the SURFACE states
/// the consequence in a sentence. The axes are still both there, still independent, and
/// still separately settable by anyone who edits `config.json`.
///
/// **AND WHY `Custom` EXISTS.** A hand-edited file can hold a window no button on the menu
/// produces. Rounding that to the nearest named choice would misreport his setting on the
/// screen that is supposed to tell him what it is, and — worse — the first click on any
/// other control would write the rounded value back. So a window that is not one of the
/// three reports as itself, and the surface shows no selection rather than a wrong one.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum RetentionChoice {
    /// 14 days or 2 GB, whichever binds first. **The shipping default** — today's
    /// behaviour, and the one an install with no `raw_retention` key already has.
    TwoWeeks,
    /// 90 days, same 2 GB ceiling. The ceiling is deliberately NOT raised with the window:
    /// it is the only thing between §2.4 and a full disk, and the surface says plainly
    /// which of the two will bind.
    ThreeMonths,
    /// Nothing is ever evicted, on either axis.
    Forever,
    /// A window that is in the file and on no menu. Reported, never written by a click.
    Custom,
}

/// 90 days. Named here rather than inline so the value the menu produces and the value the
/// menu recognizes cannot drift apart — they are the same constant read twice.
pub const THREE_MONTHS_DAYS: u64 = 90;

impl RetentionChoice {
    pub fn as_str(&self) -> &'static str {
        match self {
            RetentionChoice::TwoWeeks => "two-weeks",
            RetentionChoice::ThreeMonths => "three-months",
            RetentionChoice::Forever => "forever",
            RetentionChoice::Custom => "custom",
        }
    }

    /// Parse a wire value. `"custom"` is deliberately NOT parseable: it is a description of
    /// what is in the file, never an instruction, and a settable `custom` would be a
    /// command with no argument.
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "two-weeks" => Some(RetentionChoice::TwoWeeks),
            "three-months" => Some(RetentionChoice::ThreeMonths),
            "forever" => Some(RetentionChoice::Forever),
            _ => None,
        }
    }

    /// The window this choice means, or `None` for `Custom`.
    pub fn retention(&self) -> Option<RawRetention> {
        match self {
            RetentionChoice::TwoWeeks => Some(RawRetention::of(RAW_RETENTION_DAYS, RAW_MAX_TOTAL_BYTES)),
            RetentionChoice::ThreeMonths => Some(RawRetention::of(THREE_MONTHS_DAYS, RAW_MAX_TOTAL_BYTES)),
            RetentionChoice::Forever => Some(RawRetention::FOREVER),
            RetentionChoice::Custom => None,
        }
    }

    /// Which menu entry, if any, a stored window IS. Derived by comparing against what each
    /// entry produces, so the two directions can never disagree.
    pub fn of(retention: &RawRetention) -> Self {
        for c in [RetentionChoice::TwoWeeks, RetentionChoice::ThreeMonths, RetentionChoice::Forever] {
            if c.retention().as_ref() == Some(retention) {
                return c;
            }
        }
        RetentionChoice::Custom
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
        let config = match fs::read_to_string(&path) {
            // No file: a fresh install. Every default applies, `raw_retention` included —
            // which is the shipping window and nothing new.
            Err(_) => StoredConfig::default(),
            Ok(text) => serde_json::from_str(&text).unwrap_or_else(|_| StoredConfig {
                // A file that EXISTS and will not parse is NOT a fresh install, and the one
                // preference in here that DELETES must not be reconstructed from a guess.
                // Every other field degrading to its default costs a preference; this one
                // degrading to 14 days costs records, silently, at the next boot. So the
                // corrupt-file path keeps everything and the CEO can set it again.
                raw_retention: RawRetention::FOREVER,
                ..StoredConfig::default()
            }),
        };
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

    // ---- the raw-payload window (design §7.2) --------------------------------------

    /// How long the technical view's stored output survives. The shipping default on an
    /// install that has never set it.
    pub fn raw_retention(&self) -> RawRetention {
        self.config.raw_retention
    }

    /// Which menu entry the stored window is, or `Custom` for one that is on no menu.
    pub fn retention_choice(&self) -> RetentionChoice {
        RetentionChoice::of(&self.config.raw_retention)
    }

    /// Set the window. Takes the WINDOW, not the menu entry, so a hand-written
    /// `{"age_days": 45}` is as settable as a click and `Custom` stays describable.
    pub fn set_raw_retention(&mut self, retention: RawRetention) -> io::Result<()> {
        self.config.raw_retention = retention;
        self.persist()
    }

    /// Set the window from a menu entry. `Custom` has no window to write and is refused —
    /// it is a description of the file, never an instruction.
    pub fn set_retention_choice(&mut self, choice: RetentionChoice) -> io::Result<bool> {
        match choice.retention() {
            Some(r) => {
                self.set_raw_retention(r)?;
                Ok(true)
            }
            None => Ok(false),
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

    // ---- the raw-payload window (§7.2) ---------------------------------------------

    #[test]
    fn an_install_that_has_never_set_the_window_gets_yesterdays_behaviour() {
        // The claim the whole change stands on, at the store level: a fresh store AND a
        // config file written before this setting existed both read as the shipping
        // window — the same two constants `evict_raw` was called with before it was a
        // setting. Neither of them is "forever", and neither of them is a new number.
        let path = tmp_path("retention-default");
        let fresh = ConfigStore::open(&path).unwrap();
        assert_eq!(fresh.raw_retention(), RawRetention::of(RAW_RETENTION_DAYS, RAW_MAX_TOTAL_BYTES));
        assert_eq!(fresh.retention_choice(), RetentionChoice::TwoWeeks);

        let older = tmp_path("retention-legacy");
        std::fs::write(&older, r#"{"company_name":"Acme","assertiveness":"balanced","techy_default":true}"#).unwrap();
        let store = ConfigStore::open(&older).unwrap();
        assert_eq!(store.raw_retention(), RawRetention::default(), "an absent key is the shipping default");
        assert_eq!(store.retention_choice(), RetentionChoice::TwoWeeks);
        assert!(store.techy_default(), "and the rest of the file still reads");
        let _ = std::fs::remove_file(&older);
    }

    #[test]
    fn every_answer_to_7_2_is_a_value_the_store_can_hold_and_forever_is_one_of_them() {
        // The item, in one test. "Forever" is a real stored value that survives a restart,
        // not a sentinel someone has to remember and not a code change.
        let path = tmp_path("retention-forever");
        {
            let mut store = ConfigStore::open(&path).unwrap();
            assert!(store.set_retention_choice(RetentionChoice::Forever).unwrap());
        }
        let reopened = ConfigStore::open(&path).unwrap();
        assert_eq!(reopened.raw_retention(), RawRetention::FOREVER);
        assert!(reopened.raw_retention().is_forever(), "on BOTH axes — a ceiling that still evicts is not forever");
        assert_eq!(reopened.retention_choice(), RetentionChoice::Forever);
        // And it is a word on disk, not a number to decode.
        let on_disk = std::fs::read_to_string(&path).unwrap();
        assert!(on_disk.contains(r#""age_days": "forever""#), "readable by hand: {on_disk}");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn the_three_menu_entries_round_trip_and_custom_is_never_written_by_one() {
        let path = tmp_path("retention-menu");
        let mut store = ConfigStore::open(&path).unwrap();
        for choice in [RetentionChoice::TwoWeeks, RetentionChoice::ThreeMonths, RetentionChoice::Forever] {
            assert!(store.set_retention_choice(choice).unwrap());
            assert_eq!(store.retention_choice(), choice, "what was set is what is reported");
            assert_eq!(RetentionChoice::parse(choice.as_str()), Some(choice), "and the wire string round-trips");
        }
        assert_eq!(RetentionChoice::ThreeMonths.retention(), Some(RawRetention::of(THREE_MONTHS_DAYS, RAW_MAX_TOTAL_BYTES)));
        assert_eq!(THREE_MONTHS_DAYS, 90);
        // `custom` is a description, never an instruction: unparseable from the wire, and a
        // no-op that writes nothing if one is somehow constructed.
        assert_eq!(RetentionChoice::parse("custom"), None);
        assert_eq!(RetentionChoice::parse("two weeks"), None);
        assert_eq!(RetentionChoice::Custom.retention(), None);
        let before = store.raw_retention();
        assert!(!store.set_retention_choice(RetentionChoice::Custom).unwrap(), "refused");
        assert_eq!(store.raw_retention(), before, "and nothing was written");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_hand_written_window_is_reported_as_itself_and_never_rounded_to_a_button() {
        // Rounding a hand-edited window to the nearest named choice would misreport it on
        // the one screen whose job is to say what it is — and the next click on any OTHER
        // control would write the rounded value back over his.
        let path = tmp_path("retention-custom");
        std::fs::write(&path, r#"{"company_name":null,"raw_retention":{"age_days":45,"total_bytes":"forever"}}"#).unwrap();
        let store = ConfigStore::open(&path).unwrap();
        assert_eq!(
            store.raw_retention(),
            RawRetention { age_days: RetentionLimit::Of(45), total_bytes: RetentionLimit::Forever }
        );
        assert_eq!(store.retention_choice(), RetentionChoice::Custom);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn an_unreadable_window_keeps_data_and_leaves_every_other_preference_alone() {
        // A `raw_retention` key of the wrong shape must not fail the parse of config.json —
        // that would degrade EVERY preference to its default, this one included, back to a
        // window that deletes. It reads as forever, and the file around it still reads.
        let path = tmp_path("retention-garbage");
        std::fs::write(&path, r#"{"company_name":"Acme","assertiveness":"balanced","raw_retention":"a fortnight"}"#).unwrap();
        let store = ConfigStore::open(&path).unwrap();
        assert_eq!(store.raw_retention(), RawRetention::FOREVER, "keeps, never deletes");
        assert_eq!(store.company_name(), Some("Acme"), "and took nothing else down with it");
        assert_eq!(store.assertiveness(), Assertiveness::Balanced);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_corrupt_config_file_keeps_the_stored_output_rather_than_evicting_on_a_guess() {
        // The asymmetry, at the file level. Every other field degrading to its default
        // costs a preference the CEO can set again; `raw_retention` degrading to 14 days
        // costs records, at the next boot, with nothing on screen to say so. A file that
        // exists and will not parse is not a fresh install and is not treated as one.
        let path = tmp_path("retention-corrupt");
        std::fs::write(&path, "{ not json").unwrap();
        let store = ConfigStore::open(&path).unwrap();
        assert_eq!(store.raw_retention(), RawRetention::FOREVER);
        assert_eq!(store.retention_choice(), RetentionChoice::Forever);
        // ...while the fields whose worst case is a lost preference still take their
        // defaults, exactly as they did before.
        assert_eq!(store.assertiveness(), Assertiveness::Quiet);
        assert!(store.splash_enabled());
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
