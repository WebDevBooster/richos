//! THE LAUNCH RECORD — what a "start" is, and the log the reward logic will read.
//!
//! Ruled by the CEO on 2026-08-31 (`richos-hq/wiki/gamification.md` § "Splash tracking").
//! His purpose, in his words: *"we'll either randomly pick a splash screen from the
//! available list or deliberately show a particular splash screen to show some visual
//! rewards if the user reaches a certain milestone."* This module is the record that
//! decision will be made from. It does not make the decision, and it draws nothing.
//!
//! # A START IS A FRESH LAUNCH AFTER A QUIT, AND NOTHING ELSE
//!
//! Three kinds of beginning arrive at this file and only one of them is a start:
//!
//! | what happened | counted | splash |
//! |---|---|---|
//! | the app was quit, and launched again | YES | yes |
//! | the app died without quitting, and came back | no | NO |
//! | a second window of an app already running | no | NO |
//!
//! **Waking from sleep is not in the table because the CEO struck the category:** the app
//! was never quit, so nothing begins, and there is no code here that handles it. A wake is
//! simply a process that never stopped running and therefore never calls [`LaunchStore::begin_run`].
//!
//! # HOW THE THREE ARE TOLD APART, AND WHERE THAT IS WEAK
//!
//! One marker, `open_run`, written into the record when a run begins and cleared when the
//! app quits cleanly. Its PRESENCE at the next start is the whole signal:
//!
//!   * **absent** — the last run cleared it on its way out, so the last thing that happened
//!     was a quit. This start is FRESH.
//!   * **present** — the last run never got to clear it. Either it died, or it is still
//!     running. [`PriorRun`] is how the caller says which, and it is a parameter rather than
//!     something guessed here: an inference from silence is exactly the reasoning the
//!     continuity design forbids (§5.2), so the honest default is [`PriorRun::Unknown`] and
//!     the honest reading of Unknown is CRASH-RESTART.
//!
//! **What this gets wrong, named rather than hidden.** A clean-exit marker cannot survive a
//! power cut or a `SIGKILL`, and neither can the code that clears it. So:
//!
//!   * A genuine quit that the OS turned into a kill — a forced shutdown, a battery that
//!     ran out mid-session, "Force Quit" — leaves the marker behind and the NEXT launch
//!     reads as a crash-restart. It is not counted and shows no splash.
//!   * The reverse error is structurally impossible. The marker is cleared by exactly one
//!     path, the clean-exit one, so a real crash can never present as a fresh start.
//!
//! That asymmetry is deliberate and it is the direction to be wrong in. The cost of the
//! error we CAN make is an undercount — a milestone arrives one launch later than it might
//! have. The cost of the error we cannot make would be firing a reward at someone whose app
//! just died in front of them.
//!
//! **A second window is a different mechanism entirely,** because in this shell a second
//! window is not a second process: [`LaunchStore::next_window_kind`] answers for windows and
//! only the FIRST window of a run inherits the run's kind. That counter lives in memory and
//! is never persisted, which is what makes it correct by construction — it cannot outlive
//! the process it counts for. The multi-PROCESS case (a second copy launched while one is
//! running) is reachable through `PriorRun::Alive`, and the residual risk there is that a
//! caller who cannot check reports `Unknown`, in which case a second copy reads as a
//! crash-restart: not counted, no splash, which is the same outcome the CEO asked for.
//!
//! # STORE THE EVENTS, DERIVE THE COUNTERS
//!
//! `starts` is a list of timestamps. Today / this week / this month / this year / total are
//! [`LaunchCounts`], computed from it at read time. There is no stored counter anywhere in
//! this file, on purpose: five counters are five things that can disagree with each other
//! and with the log; one log cannot disagree with itself. One `u64` per launch is about
//! 5 KB a year at a launch a day.
//!
//! # STORE UTC, BUCKET LOCAL
//!
//! Every timestamp here is UTC epoch millis — one storage format, sortable, no DST gaps or
//! repeats to encode. Every BUCKET is computed against the reader's LOCAL calendar, at read
//! time, from a UTC offset the caller supplies ([`LaunchCounts::of`]).
//!
//! The CEO ruled this after asking whether time should be local instead: the market is
//! US founder-CEOs, UTC-5 to UTC-8, whose evening is already tomorrow in UTC. Bucketing in
//! UTC would mis-date the single commonest usage moment for the entire market, every day.
//! The stored bytes are identical either way — only the query changes — so this is
//! reversible with no migration.
//!
//! **Where the local bucketing is approximate, stated exactly.** The caller supplies ONE
//! offset, the one in force now. Bucket boundaries further back than the last DST change are
//! therefore computed with today's offset rather than the one that was in force at the
//! boundary. The error is bounded by the size of the DST step (60 minutes almost everywhere)
//! and it can only move a launch that fell WITHIN that many minutes of a local midnight that
//! is also a bucket boundary — in practice, `this_year` around New Year when the boundary is
//! on the other side of a DST change. `today` is never affected, because its boundary is
//! always within the last 24 hours of the offset being passed. See
//! `the_dst_error_is_bounded_by_one_hour_and_only_at_a_boundary` below, which measures it
//! rather than asserting it is small.
//!
//! # LOCAL ONLY, NEVER OUTBOUND
//!
//! This is data about the CEO's own working life. It goes in one file on his disk and there
//! is no way out of this machine anywhere in its call graph — asserted mechanically, in the
//! same shape as the feedback channel's guarantee, by
//! `crates/richos-core/tests/launch_no_outbound_tests.rs`.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// The record's shape number, bumped whenever a field changes meaning.
///
/// **Why a version at all**, since nothing has migrated yet: without one, a file this build
/// cannot understand deserializes field-by-field into defaults, an absent `starts` reads as
/// an empty log, and an empty log reads as *this CEO has never opened the app*. The first
/// thing a reward system does with that is fire the first-run reward at the person who has
/// been here longest. So an unrecognized version is [`LaunchStore::readable`] `== false`,
/// which is a state this module reports rather than papers over.
pub const LAUNCH_SCHEMA_VERSION: u32 = 1;

/// How many recently-shown splash ids the ring keeps.
///
/// **A ring rather than a single last-id**, at the CEO's direction: remembering only the
/// last one prevents an immediate repeat and nothing else, so a draw can show the same
/// three all week and still never repeat back-to-back. Five is enough to make a run of
/// three visibly unlikely against a library of eighteen while still leaving most of the
/// library eligible on any given draw.
pub const RECENCY_RING_LEN: usize = 5;

/// Which day a week begins on, for the `this_week` bucket.
///
/// **NOT RULED, and named here so it is one token to change.** The CEO settled the day
/// boundary and the local-vs-UTC question; he was not asked which day starts a week. ISO
/// Monday is the choice made here because these are work-rhythm counts for a working CEO,
/// and because ISO-8601 is the only answer that is a standard rather than a regional habit
/// (US calendars start Sunday, which is the alternative if he prefers it).
const WEEK_STARTS_ON: Weekday = Weekday::Monday;

/// Days of the week, `Sunday == 0`, matching the epoch-derived arithmetic below.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Weekday {
    #[allow(dead_code)]
    Sunday = 0,
    Monday = 1,
}

/// What kind of beginning this is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum LaunchKind {
    /// The app was quit and has been launched again. **The only one that counts, and the
    /// only one that shows a splash.**
    Fresh,
    /// The last run ended without quitting. Not counted, no splash — and the CEO's separate
    /// requirement applies: he comes back to exactly where he was.
    CrashRestart,
    /// A window opened on a run that was already going, or a second copy launched while one
    /// is running. Nothing begins; not counted, no splash.
    SecondWindow,
}

impl LaunchKind {
    /// The wire string, matched verbatim by `app/ui/splash.js`'s `KIND_FRESH` so the two
    /// sides cannot drift into disagreeing about what a fresh launch is called.
    pub fn as_str(&self) -> &'static str {
        match self {
            LaunchKind::Fresh => "fresh",
            LaunchKind::CrashRestart => "crash-restart",
            LaunchKind::SecondWindow => "second-window",
        }
    }

    /// Whether this beginning is a START — i.e. whether it goes in the log.
    pub fn is_start(&self) -> bool {
        matches!(self, LaunchKind::Fresh)
    }

    /// Whether the opening screen shows. Identical to [`LaunchKind::is_start`] today and
    /// deliberately a SEPARATE question: "which of these counts" and "which of these gets a
    /// ceremony" are two rulings that happened to agree, not one rule.
    pub fn shows_splash(&self) -> bool {
        matches!(self, LaunchKind::Fresh)
    }
}

/// What the caller knows about the run that left the marker behind.
///
/// A parameter and not a guess. The continuity design's §5.2 rule — never infer death from
/// silence, require a positive signal — applies here exactly as it applies to a worker: this
/// module is handed an answer or it is handed `Unknown`, and it never manufactures one from
/// elapsed time.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PriorRun {
    /// Nobody checked, or the check is not available on this platform. Read as a
    /// crash-restart: not counted, no splash, and he comes back where he was.
    Unknown,
    /// Positively observed to still be running. This launch is a second copy of a live app.
    Alive,
    /// Positively observed to be gone. A crash-restart.
    Gone,
}

/// Today / this week / this month / this year / total, all derived, none stored.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchCounts {
    pub today: u32,
    pub this_week: u32,
    pub this_month: u32,
    pub this_year: u32,
    pub total: u32,
}

impl LaunchCounts {
    /// Bucket a UTC log against a LOCAL calendar.
    ///
    /// `utc_offset_minutes` is the reader's offset from UTC, positive east — the negation of
    /// JavaScript's `Date.prototype.getTimezoneOffset()`, which is where the shell gets it.
    /// So US Pacific daylight time is `-420`, not `420`.
    pub fn of(starts: &[u64], now_millis: u64, utc_offset_minutes: i32) -> LaunchCounts {
        let now = now_millis as i64;
        let today_index = local_day_index(now, utc_offset_minutes);
        let (year, month, _day) = civil_from_days(today_index);

        let day_start = day_start_utc_millis(today_index, utc_offset_minutes);
        let week_start = day_start_utc_millis(week_start_index(today_index), utc_offset_minutes);
        let month_start =
            day_start_utc_millis(days_from_civil(year, month, 1), utc_offset_minutes);
        let year_start = day_start_utc_millis(days_from_civil(year, 1, 1), utc_offset_minutes);

        let mut counts = LaunchCounts { today: 0, this_week: 0, this_month: 0, this_year: 0, total: 0 };
        for &t in starts {
            let t = t as i64;
            counts.total += 1;
            if t >= year_start {
                counts.this_year += 1;
            }
            if t >= month_start {
                counts.this_month += 1;
            }
            if t >= week_start {
                counts.this_week += 1;
            }
            if t >= day_start {
                counts.today += 1;
            }
        }
        counts
    }
}

// -------------------------------------------------------------------------------------
// The local calendar, from first principles
// -------------------------------------------------------------------------------------
//
// Four small integer functions instead of a date crate. `richos-core` has four
// dependencies and none of them can reach off this machine, which is a property
// `launch_no_outbound_tests.rs` asserts by name; adding a fifth to divide by 86,400,000
// would be a poor trade. The civil-date conversions are Howard Hinnant's `days_from_civil`
// / `civil_from_days`, proven over the full ±400-year era below.

const MS_PER_DAY: i64 = 86_400_000;
const MS_PER_MINUTE: i64 = 60_000;

/// Which local day a UTC instant falls in, as a count of days since 1970-01-01 LOCAL.
fn local_day_index(utc_millis: i64, utc_offset_minutes: i32) -> i64 {
    (utc_millis + utc_offset_minutes as i64 * MS_PER_MINUTE).div_euclid(MS_PER_DAY)
}

/// The UTC instant at which a local day begins.
fn day_start_utc_millis(day_index: i64, utc_offset_minutes: i32) -> i64 {
    day_index * MS_PER_DAY - utc_offset_minutes as i64 * MS_PER_MINUTE
}

/// `0 == Sunday`. 1970-01-01 was a Thursday, hence the `+ 4`.
fn weekday_of(day_index: i64) -> i64 {
    (day_index + 4).rem_euclid(7)
}

/// The first day of the week `day_index` falls in.
fn week_start_index(day_index: i64) -> i64 {
    let offset_back = (weekday_of(day_index) - WEEK_STARTS_ON as i64).rem_euclid(7);
    day_index - offset_back
}

/// Days since 1970-01-01 for a civil (proleptic Gregorian) date.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 }.div_euclid(400);
    let yoe = y - era * 400;
    let mp = ((m as i64) + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The civil date for a count of days since 1970-01-01.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 }.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

// -------------------------------------------------------------------------------------
// The stored record
// -------------------------------------------------------------------------------------

/// The run that is currently open — the clean-exit marker, inverted.
///
/// It is written when a run begins and removed when the app quits cleanly, so finding one
/// at startup means the last run did not get to say goodbye. `token` is opaque to this
/// module: the shell puts its process id in it so a future liveness check has something to
/// check, and nothing here ever interprets it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct OpenRun {
    started_at: u64,
    #[serde(default)]
    token: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct StoredLaunches {
    /// See [`LAUNCH_SCHEMA_VERSION`]. NOT `#[serde(default)]` — an absent version is the
    /// case this field exists to catch, and defaulting it to 1 would announce that a file
    /// written by something else is one of ours.
    schema_version: u32,
    /// First-run marker: when this install first began. Every milestone measured in days
    /// is measured from here.
    installed_at: u64,
    /// The log. UTC epoch millis, one entry per START, append-only, ascending.
    #[serde(default)]
    starts: Vec<u64>,
    /// The last [`RECENCY_RING_LEN`] splash ids shown, most recent FIRST.
    #[serde(default)]
    recent_splashes: Vec<String>,
    /// Which rewards have already fired, and when. A milestone shows once.
    #[serde(default)]
    rewards_fired: BTreeMap<String, u64>,
    /// Present while a run is in progress. See [`OpenRun`].
    #[serde(default)]
    open_run: Option<OpenRun>,
}

impl StoredLaunches {
    fn new(now_millis: u64) -> Self {
        StoredLaunches {
            schema_version: LAUNCH_SCHEMA_VERSION,
            installed_at: now_millis,
            starts: Vec::new(),
            recent_splashes: Vec::new(),
            rewards_fired: BTreeMap::new(),
            open_run: None,
        }
    }
}

/// The launch record on disk, and the only thing that writes it.
///
/// **Deliberately NOT part of `ConfigStore`.** That file's own first paragraph says what it
/// is for: *"mutable point-in-time state, not an event stream"*. `starts` is an event
/// stream, it grows forever, and putting it in `config.json` would rewrite every one of the
/// CEO's preferences on every launch to append eight bytes. Same directory, same durability
/// posture, separate file.
pub struct LaunchStore {
    path: PathBuf,
    record: StoredLaunches,
    /// False when the file on disk exists and this build cannot understand it. Every
    /// mutator becomes a no-op and every reader reports `None`, because the one thing that
    /// must never happen is overwriting a history we could not read.
    readable: bool,
    /// Why it is unreadable, for an operator's eyes. `None` when it is readable.
    unreadable_reason: Option<String>,
    /// This run's kind, decided once by [`LaunchStore::begin_run`]. In memory only.
    run_kind: Option<LaunchKind>,
    /// How many windows this run has opened. In memory only, and that is the point: a
    /// window counter that could survive its own process would be lying at the next start.
    windows_opened: u32,
}

impl LaunchStore {
    /// Open the record, or start a fresh one if there is no file.
    ///
    /// A file that will not parse, or that carries a version this build does not know, is
    /// NOT treated as a fresh install — see [`LaunchStore::readable`].
    pub fn open(path: impl AsRef<Path>, now_millis: u64) -> io::Result<Self> {
        let path = path.as_ref().to_path_buf();
        let (record, readable, reason) = match fs::read_to_string(&path) {
            // No file: this install begins now.
            Err(_) => (StoredLaunches::new(now_millis), true, None),
            Ok(text) => match serde_json::from_str::<StoredLaunches>(&text) {
                Ok(r) if r.schema_version == LAUNCH_SCHEMA_VERSION => (r, true, None),
                Ok(r) => (
                    StoredLaunches::new(now_millis),
                    false,
                    Some(format!(
                        "the launch record on disk is schema version {} and this build knows \
                         version {LAUNCH_SCHEMA_VERSION}; it is being left exactly as it is \
                         rather than read as an empty history",
                        r.schema_version
                    )),
                ),
                Err(e) => (
                    StoredLaunches::new(now_millis),
                    false,
                    Some(format!(
                        "the launch record on disk will not parse ({e}); it is being left \
                         exactly as it is rather than read as an empty history"
                    )),
                ),
            },
        };
        Ok(LaunchStore {
            path,
            record,
            readable,
            unreadable_reason: reason,
            run_kind: None,
            windows_opened: 0,
        })
    }

    /// Whether the file on disk was understood. When false, this store reads and writes
    /// nothing — it exists only to say so.
    pub fn readable(&self) -> bool {
        self.readable
    }

    /// Why it is unreadable, or `None` when it is fine.
    pub fn unreadable_reason(&self) -> Option<&str> {
        self.unreadable_reason.as_deref()
    }

    /// Classify this run and record it. **Call exactly once per process, at startup.**
    ///
    /// `token` is opaque and stored as-is (the shell passes its process id). `prior` is what
    /// the caller positively knows about the run that left a marker behind — see [`PriorRun`].
    ///
    /// A FRESH run appends to the log and takes the marker. A crash-restart takes the marker
    /// without appending. A second copy touches neither, because the marker belongs to the
    /// run that is still holding it.
    pub fn begin_run(
        &mut self,
        now_millis: u64,
        token: impl Into<String>,
        prior: PriorRun,
    ) -> io::Result<LaunchKind> {
        let kind = match (&self.record.open_run, prior) {
            (None, _) => LaunchKind::Fresh,
            (Some(_), PriorRun::Alive) => LaunchKind::SecondWindow,
            (Some(_), PriorRun::Gone) | (Some(_), PriorRun::Unknown) => LaunchKind::CrashRestart,
        };
        self.run_kind = Some(kind);
        if !self.readable {
            return Ok(kind);
        }
        match kind {
            LaunchKind::Fresh => {
                if self.record.starts.is_empty() && self.record.installed_at == 0 {
                    self.record.installed_at = now_millis;
                }
                self.record.starts.push(now_millis);
                self.record.open_run =
                    Some(OpenRun { started_at: now_millis, token: token.into() });
                self.persist()?;
            }
            LaunchKind::CrashRestart => {
                self.record.open_run =
                    Some(OpenRun { started_at: now_millis, token: token.into() });
                self.persist()?;
            }
            // Nothing. The live run owns the marker and this copy is not a start.
            LaunchKind::SecondWindow => {}
        }
        Ok(kind)
    }

    /// The kind to hand the NEXT window that opens.
    ///
    /// The first window of a run inherits the run's kind; every window after it is a second
    /// window, whatever the run was. A crash-restart that opens two windows therefore
    /// produces `CrashRestart` then `SecondWindow`, and neither shows a splash.
    ///
    /// Returns `SecondWindow` if called before [`LaunchStore::begin_run`], which is the
    /// conservative reading of "we were never told what this run is".
    pub fn next_window_kind(&mut self) -> LaunchKind {
        let kind = match (self.windows_opened, self.run_kind) {
            (0, Some(k)) => k,
            _ => LaunchKind::SecondWindow,
        };
        self.windows_opened += 1;
        kind
    }

    /// This run's kind, or `None` before it has begun.
    pub fn run_kind(&self) -> Option<LaunchKind> {
        self.run_kind
    }

    /// The app is quitting cleanly. Clears the marker, which is what makes the NEXT launch
    /// read as fresh.
    ///
    /// Idempotent, and safe to call when no run is open.
    pub fn note_clean_exit(&mut self) -> io::Result<()> {
        if !self.readable || self.record.open_run.is_none() {
            return Ok(());
        }
        self.record.open_run = None;
        self.persist()
    }

    /// Whether a run is currently marked open — i.e. whether a crash right now would be
    /// seen as one at the next launch.
    pub fn run_is_open(&self) -> bool {
        self.record.open_run.is_some()
    }

    /// Today / week / month / year / total against the reader's local calendar. `None` when
    /// the record could not be read, because a zero is a claim and this is not one.
    pub fn counts(&self, now_millis: u64, utc_offset_minutes: i32) -> Option<LaunchCounts> {
        if !self.readable {
            return None;
        }
        Some(LaunchCounts::of(&self.record.starts, now_millis, utc_offset_minutes))
    }

    /// When this install first began, or `None` when unknown.
    pub fn installed_at(&self) -> Option<u64> {
        if !self.readable {
            return None;
        }
        Some(self.record.installed_at)
    }

    /// The whole log, ascending. Exposed so the reward logic can ask questions this module
    /// has no opinion about (runs of consecutive days, gaps, time of day).
    pub fn starts(&self) -> &[u64] {
        &self.record.starts
    }

    /// The last [`RECENCY_RING_LEN`] splash ids shown, most recent FIRST.
    pub fn recent_splashes(&self) -> &[String] {
        &self.record.recent_splashes
    }

    /// Record that a splash was shown, pushing it onto the front of the ring.
    ///
    /// Repeats are kept rather than collapsed: the ring is a history of what was actually on
    /// screen, and "the same one three launches running" is precisely the fact a draw wants
    /// to be able to see.
    pub fn note_splash_shown(&mut self, id: &str) -> io::Result<()> {
        if !self.readable || id.is_empty() {
            return Ok(());
        }
        self.record.recent_splashes.insert(0, id.to_string());
        self.record.recent_splashes.truncate(RECENCY_RING_LEN);
        self.persist()
    }

    /// When a named reward fired, or `None` if it never has.
    pub fn reward_fired_at(&self, key: &str) -> Option<u64> {
        if !self.readable {
            return None;
        }
        self.record.rewards_fired.get(key).copied()
    }

    /// Record that a reward has fired. Idempotent — the FIRST firing wins and every later
    /// call is a no-op that does not touch the disk, so a milestone shows once.
    ///
    /// Returns whether it wrote.
    pub fn note_reward_fired(&mut self, key: &str, now_millis: u64) -> io::Result<bool> {
        if !self.readable || key.is_empty() || self.record.rewards_fired.contains_key(key) {
            return Ok(false);
        }
        self.record.rewards_fired.insert(key.to_string(), now_millis);
        self.persist()?;
        Ok(true)
    }

    /// The schema version of the record in memory.
    pub fn schema_version(&self) -> u32 {
        self.record.schema_version
    }

    /// Write the record, whole, via a temporary file and a rename.
    ///
    /// `config.rs` writes in place, which is right for a file whose worst loss is one
    /// preference. This one holds every launch this install has ever had, and a partial
    /// write of it reads at the next boot as *"brand new user"* — the exact failure the
    /// schema version exists to prevent, arriving by a different door. A rename is atomic on
    /// every platform this ships to, so the file on disk is always one whole record or the
    /// previous whole record.
    fn persist(&self) -> io::Result<()> {
        if let Some(dir) = self.path.parent() {
            fs::create_dir_all(dir)?;
        }
        let serialized = serde_json::to_string_pretty(&self.record)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        let temporary = self.path.with_extension("json.writing");
        fs::write(&temporary, serialized)?;
        fs::rename(&temporary, &self.path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_path(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "richos-launch-test-{tag}-{}-{}.json",
            std::process::id(),
            crate::util::now_millis()
        ))
    }

    /// 2026-08-31T09:00:00Z, the anchor every timing case below is measured from.
    const T0: u64 = 1_788_166_800_000;

    /// US Pacific daylight time. Negative because the offset is from UTC, positive east.
    const PACIFIC: i32 = -420;

    // ---- the three kinds ---------------------------------------------------------------

    #[test]
    fn the_first_launch_of_a_new_install_is_fresh_and_is_counted() {
        let path = tmp_path("first");
        let mut store = LaunchStore::open(&path, T0).unwrap();
        let kind = store.begin_run(T0, "1", PriorRun::Unknown).unwrap();
        assert_eq!(kind, LaunchKind::Fresh);
        assert!(kind.is_start());
        assert!(kind.shows_splash());
        assert_eq!(store.starts(), &[T0]);
        assert_eq!(store.installed_at(), Some(T0));
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_quit_and_a_relaunch_is_a_second_start() {
        let path = tmp_path("quit-relaunch");
        {
            let mut store = LaunchStore::open(&path, T0).unwrap();
            store.begin_run(T0, "1", PriorRun::Unknown).unwrap();
            store.note_clean_exit().unwrap();
        }
        let mut store = LaunchStore::open(&path, T0 + 60_000).unwrap();
        assert_eq!(store.begin_run(T0 + 60_000, "2", PriorRun::Unknown).unwrap(), LaunchKind::Fresh);
        assert_eq!(store.starts(), &[T0, T0 + 60_000], "two quits, two starts");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_run_that_never_said_goodbye_comes_back_as_a_crash_restart_and_is_not_counted() {
        let path = tmp_path("crash");
        {
            let mut store = LaunchStore::open(&path, T0).unwrap();
            store.begin_run(T0, "1", PriorRun::Unknown).unwrap();
            // No `note_clean_exit`. This is what a power cut leaves behind.
        }
        let mut store = LaunchStore::open(&path, T0 + 5_000).unwrap();
        let kind = store.begin_run(T0 + 5_000, "2", PriorRun::Unknown).unwrap();
        assert_eq!(kind, LaunchKind::CrashRestart);
        assert!(!kind.is_start(), "a crash-restart is not a start");
        assert!(!kind.shows_splash(), "and it shows no splash");
        assert_eq!(store.starts(), &[T0], "the log still holds exactly one start");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_crash_restart_takes_the_marker_so_a_second_crash_is_still_a_crash() {
        let path = tmp_path("crash-twice");
        {
            let mut s = LaunchStore::open(&path, T0).unwrap();
            s.begin_run(T0, "1", PriorRun::Unknown).unwrap();
        }
        {
            let mut s = LaunchStore::open(&path, T0 + 1_000).unwrap();
            assert_eq!(s.begin_run(T0 + 1_000, "2", PriorRun::Unknown).unwrap(), LaunchKind::CrashRestart);
        }
        let mut s = LaunchStore::open(&path, T0 + 2_000).unwrap();
        assert_eq!(s.begin_run(T0 + 2_000, "3", PriorRun::Unknown).unwrap(), LaunchKind::CrashRestart);
        assert_eq!(s.starts().len(), 1);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_live_prior_run_makes_this_a_second_window_not_a_crash_restart() {
        let path = tmp_path("second-copy");
        {
            let mut s = LaunchStore::open(&path, T0).unwrap();
            s.begin_run(T0, "1", PriorRun::Unknown).unwrap();
        }
        let mut s = LaunchStore::open(&path, T0 + 1_000).unwrap();
        let kind = s.begin_run(T0 + 1_000, "2", PriorRun::Alive).unwrap();
        assert_eq!(kind, LaunchKind::SecondWindow);
        assert!(!kind.is_start());
        assert!(!kind.shows_splash());
        assert_eq!(s.starts(), &[T0]);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn only_the_first_window_of_a_run_inherits_the_runs_kind() {
        let path = tmp_path("windows");
        let mut s = LaunchStore::open(&path, T0).unwrap();
        s.begin_run(T0, "1", PriorRun::Unknown).unwrap();
        assert_eq!(s.next_window_kind(), LaunchKind::Fresh);
        assert_eq!(s.next_window_kind(), LaunchKind::SecondWindow);
        assert_eq!(s.next_window_kind(), LaunchKind::SecondWindow);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_window_asked_for_before_the_run_began_is_a_second_window() {
        let path = tmp_path("window-early");
        let mut s = LaunchStore::open(&path, T0).unwrap();
        assert_eq!(s.next_window_kind(), LaunchKind::SecondWindow);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn the_window_counter_never_survives_its_own_process() {
        // Two stores over the same file are two processes. The second one's window counter
        // starts at zero, which is what makes "first window of THIS run" mean anything.
        let path = tmp_path("window-scope");
        {
            let mut s = LaunchStore::open(&path, T0).unwrap();
            s.begin_run(T0, "1", PriorRun::Unknown).unwrap();
            assert_eq!(s.next_window_kind(), LaunchKind::Fresh);
            assert_eq!(s.next_window_kind(), LaunchKind::SecondWindow);
            s.note_clean_exit().unwrap();
        }
        let mut s = LaunchStore::open(&path, T0 + 1_000).unwrap();
        s.begin_run(T0 + 1_000, "2", PriorRun::Unknown).unwrap();
        assert_eq!(s.next_window_kind(), LaunchKind::Fresh, "a new run's first window is its own");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn the_wire_strings_are_the_ones_the_web_layer_matches() {
        assert_eq!(LaunchKind::Fresh.as_str(), "fresh");
        assert_eq!(LaunchKind::CrashRestart.as_str(), "crash-restart");
        assert_eq!(LaunchKind::SecondWindow.as_str(), "second-window");
    }

    // ---- store the events, derive the counters -----------------------------------------

    #[test]
    fn there_is_no_stored_counter_anywhere_in_the_record() {
        // The claim is structural, so it is checked against the SERIALIZED record rather
        // than asserted in a comment: if someone adds `total: u32` to `StoredLaunches` to
        // save a loop, this fails.
        let path = tmp_path("no-counters");
        let mut s = LaunchStore::open(&path, T0).unwrap();
        s.begin_run(T0, "1", PriorRun::Unknown).unwrap();
        let text = fs::read_to_string(&path).unwrap();
        for banned in ["total", "count", "today", "this_week", "this_month", "this_year", "streak"] {
            assert!(
                !text.contains(banned),
                "the record on disk carries a stored counter `{banned}` — derive it instead:\n{text}"
            );
        }
        let _ = fs::remove_file(&path);
    }

    // ---- store UTC, bucket local -------------------------------------------------------

    #[test]
    fn the_civil_date_conversions_round_trip_over_four_centuries() {
        // The bucketing is only as good as this pair, so it is proven rather than trusted:
        // every day from 1600-01-01 to 2400-01-01 there and back again.
        let from = days_from_civil(1600, 1, 1);
        let to = days_from_civil(2400, 1, 1);
        assert_eq!(to - from, 292_194, "800 years is 292,194 days");
        let mut checked = 0u32;
        for z in from..to {
            let (y, m, d) = civil_from_days(z);
            assert_eq!(days_from_civil(y, m, d), z, "round trip failed at day {z}");
            checked += 1;
        }
        assert_eq!(checked, 292_194);
    }

    #[test]
    fn nineteen_seventy_january_first_was_a_thursday() {
        assert_eq!(weekday_of(0), 4, "0 = Sunday, so Thursday is 4");
        // And the anchor this suite uses: 2026-08-31 is a Monday.
        let anchor = local_day_index(T0 as i64, 0);
        assert_eq!(civil_from_days(anchor), (2026, 8, 31));
        assert_eq!(weekday_of(anchor), 1, "2026-08-31 is a Monday");
    }

    #[test]
    fn an_evening_launch_in_california_is_bucketed_on_the_day_he_lived_it() {
        // THE CASE THE RULING IS ABOUT, in numbers.
        //
        //   A: 2026-08-31T04:00:00Z = 2026-08-30 21:00 Pacific — Sunday evening
        //   B: 2026-08-31T08:00:00Z = 2026-08-31 01:00 Pacific — Monday, just after midnight
        //   now: 2026-08-31T09:00:00Z = 2026-08-31 02:00 Pacific
        //
        // Both A and B are 31 August in UTC. Only B is 31 August where he is sitting.
        let a = 1_788_148_800_000u64; // 2026-08-31T04:00:00Z
        let b = 1_788_163_200_000u64; // 2026-08-31T08:00:00Z
        assert_eq!(civil_from_days(local_day_index(a as i64, 0)), (2026, 8, 31), "A is the 31st in UTC");
        assert_eq!(civil_from_days(local_day_index(a as i64, PACIFIC)), (2026, 8, 30), "and the 30th in Pacific");

        let local = LaunchCounts::of(&[a, b], T0, PACIFIC);
        let utc = LaunchCounts::of(&[a, b], T0, 0);
        assert_eq!(local.today, 1, "locally, one launch has happened today");
        assert_eq!(utc.today, 2, "in UTC, two — and that is the wrong answer for him");
        assert_eq!(local.total, 2);
        assert_eq!(utc.total, 2, "total is the one bucket that cannot disagree");
    }

    #[test]
    fn new_years_eve_in_california_belongs_to_the_year_he_spent_it_in() {
        // The sharpest form of the same thing, across a YEAR boundary.
        //
        //   launch: 2027-01-01T05:00:00Z = 2026-12-31 21:00 Pacific — New Year's Eve
        //   now:    2027-01-01T17:00:00Z = 2027-01-01 09:00 Pacific — New Year's Day
        let launch = 1_798_779_600_000u64; // 2027-01-01T05:00:00Z
        let now = 1_798_822_800_000u64; // 2027-01-01T17:00:00Z
        assert_eq!(civil_from_days(local_day_index(launch as i64, PACIFIC)), (2026, 12, 31));
        assert_eq!(civil_from_days(local_day_index(now as i64, PACIFIC)), (2027, 1, 1));

        let local = LaunchCounts::of(&[launch], now, PACIFIC);
        let utc = LaunchCounts::of(&[launch], now, 0);
        assert_eq!(local.this_year, 0, "he opened it last year, where he was");
        assert_eq!(utc.this_year, 1, "UTC says this year, and UTC is not where he was");
        assert_eq!(local.total, 1);
    }

    #[test]
    fn the_week_bucket_runs_from_monday_and_says_so() {
        // 2026-08-31 is a Monday, so `now` is the first day of its week and the Sunday
        // before it is a different week.
        let monday_index = local_day_index(T0 as i64, PACIFIC);
        assert_eq!(week_start_index(monday_index), monday_index, "Monday starts its own week");
        let sunday_evening = day_start_utc_millis(monday_index, PACIFIC) - 3_600_000; // 23:00 Sunday
        let monday_morning = day_start_utc_millis(monday_index, PACIFIC) + 3_600_000; // 01:00 Monday
        let counts = LaunchCounts::of(&[sunday_evening as u64, monday_morning as u64], T0, PACIFIC);
        assert_eq!(counts.this_week, 1, "only the Monday launch is in this week");
        assert_eq!(counts.today, 1);
        assert_eq!(counts.this_month, 2, "both are in August");
        assert_eq!(counts.total, 2);
    }

    #[test]
    fn the_four_buckets_nest() {
        // A launch in this week is necessarily in this month is necessarily in this year.
        // Sixty launches an hour apart ending at `now` exercise all four at once.
        let starts: Vec<u64> = (0..60).map(|i| T0 - i * 3_600_000).collect();
        let c = LaunchCounts::of(&starts, T0, PACIFIC);
        assert!(c.today <= c.this_week, "{c:?}");
        assert!(c.this_week <= c.this_month, "{c:?}");
        assert!(c.this_month <= c.this_year, "{c:?}");
        assert!(c.this_year <= c.total, "{c:?}");
        assert_eq!(c.total, 60);
        // now is 02:00 Pacific on Monday the 31st, so exactly three launches (02:00, 01:00,
        // 00:00) are today and the rest fell on Sunday.
        assert_eq!(c.today, 3, "02:00, 01:00 and 00:00 Pacific");
        assert_eq!(c.this_week, 3, "the week started at the same midnight");
        assert_eq!(c.this_month, 60, "all sixty are in August");
    }

    #[test]
    fn an_empty_log_is_all_zeroes_and_that_is_the_only_honest_zero() {
        let c = LaunchCounts::of(&[], T0, PACIFIC);
        assert_eq!(c, LaunchCounts { today: 0, this_week: 0, this_month: 0, this_year: 0, total: 0 });
    }

    #[test]
    fn the_dst_error_is_bounded_by_one_hour_and_only_at_a_boundary() {
        // THE APPROXIMATION, MEASURED. The caller passes ONE offset — today's. A bucket
        // boundary on the other side of a DST change is therefore computed an hour out.
        //
        // Reading in August (Pacific daylight, -420) about a launch near local New Year,
        // when the offset in force THEN was standard time (-480):
        //
        //   true local New Year 2027 in Pacific STANDARD time = 2027-01-01T08:00:00Z
        //   the boundary this code computes with the summer offset = 2027-01-01T07:00:00Z
        //
        // So a launch in the hour between them is bucketed as this year when it was in
        // fact last year. The window is exactly one hour wide, and nothing outside it moves.
        let boundary_standard = 1_798_790_400_000i64; // 2027-01-01T08:00:00Z
        let boundary_computed = day_start_utc_millis(days_from_civil(2027, 1, 1), -420);
        assert_eq!(boundary_computed, 1_798_786_800_000, "2027-01-01T07:00:00Z");
        assert_eq!(
            boundary_standard - boundary_computed,
            3_600_000,
            "the error is exactly the DST step, 60 minutes — no more"
        );

        // A launch half an hour inside the window is the one that moves.
        let inside = (boundary_computed + 1_800_000) as u64;
        let now = 1_798_822_800_000u64; // 2027-01-01T17:00:00Z
        assert_eq!(LaunchCounts::of(&[inside], now, -420).this_year, 1, "counted");
        assert_eq!(LaunchCounts::of(&[inside], now, -480).this_year, 0, "and would not be at the true offset");

        // And `today` is never exposed to it: its boundary is always within the last 24
        // hours of the offset being passed, so the offset in force is the offset supplied.
        let day_boundary = day_start_utc_millis(local_day_index(now as i64, -480), -480);
        assert!(now as i64 - day_boundary < MS_PER_DAY);
    }

    // ---- the ring, the install date, the rewards, the version --------------------------

    #[test]
    fn the_ring_keeps_the_last_five_most_recent_first_and_no_more() {
        let path = tmp_path("ring");
        let mut s = LaunchStore::open(&path, T0).unwrap();
        for id in ["v1", "v2", "v3", "v4", "v5", "v6", "v7"] {
            s.note_splash_shown(id).unwrap();
        }
        assert_eq!(s.recent_splashes(), &["v7", "v6", "v5", "v4", "v3"]);
        assert_eq!(s.recent_splashes().len(), RECENCY_RING_LEN);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn the_ring_keeps_repeats_because_a_repeat_is_the_fact_worth_seeing() {
        let path = tmp_path("ring-repeat");
        let mut s = LaunchStore::open(&path, T0).unwrap();
        for id in ["v3", "v3", "v3"] {
            s.note_splash_shown(id).unwrap();
        }
        assert_eq!(s.recent_splashes(), &["v3", "v3", "v3"], "three in a row is visible, not collapsed");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn the_ring_survives_a_relaunch() {
        let path = tmp_path("ring-durable");
        {
            let mut s = LaunchStore::open(&path, T0).unwrap();
            s.note_splash_shown("v9").unwrap();
        }
        let s = LaunchStore::open(&path, T0).unwrap();
        assert_eq!(s.recent_splashes(), &["v9"]);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn the_install_date_is_written_once_and_never_moves() {
        let path = tmp_path("installed");
        {
            let mut s = LaunchStore::open(&path, T0).unwrap();
            s.begin_run(T0, "1", PriorRun::Unknown).unwrap();
            s.note_clean_exit().unwrap();
        }
        let mut s = LaunchStore::open(&path, T0 + 86_400_000).unwrap();
        s.begin_run(T0 + 86_400_000, "2", PriorRun::Unknown).unwrap();
        assert_eq!(s.installed_at(), Some(T0), "a day later, still the original install");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_reward_fires_once() {
        let path = tmp_path("reward");
        let mut s = LaunchStore::open(&path, T0).unwrap();
        assert!(s.note_reward_fired("thirty-days", T0).unwrap(), "the first firing writes");
        assert!(!s.note_reward_fired("thirty-days", T0 + 999).unwrap(), "and every later one is a no-op");
        assert_eq!(s.reward_fired_at("thirty-days"), Some(T0), "the original timestamp stands");
        assert_eq!(s.reward_fired_at("never-fired"), None);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn rewards_survive_a_relaunch() {
        let path = tmp_path("reward-durable");
        {
            let mut s = LaunchStore::open(&path, T0).unwrap();
            s.note_reward_fired("first-run", T0).unwrap();
        }
        let s = LaunchStore::open(&path, T0).unwrap();
        assert_eq!(s.reward_fired_at("first-run"), Some(T0));
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_record_from_a_future_version_is_never_read_as_a_brand_new_user() {
        // THE FAILURE THE VERSION FIELD EXISTS FOR. A file this build cannot understand
        // must not deserialize into zeros — a zero log reads as "he has never opened this",
        // which fires the first-run reward at the person who has been here longest.
        let path = tmp_path("future-version");
        fs::write(
            &path,
            r#"{"schema_version":99,"installed_at":1,"starts":[1,2,3],"recent_splashes":["v4"],"rewards_fired":{},"open_run":null}"#,
        )
        .unwrap();
        let before = fs::read_to_string(&path).unwrap();

        let mut s = LaunchStore::open(&path, T0).unwrap();
        assert!(!s.readable(), "version 99 is not version 1");
        assert!(s.unreadable_reason().unwrap().contains("99"), "and it says which version it found");
        assert_eq!(s.counts(T0, PACIFIC), None, "no counts, rather than a zero that is a lie");
        assert_eq!(s.installed_at(), None);
        assert_eq!(s.reward_fired_at("first-run"), None);

        // AND IT DOES NOT WRITE. Its history is intact, byte for byte, after a full run.
        s.begin_run(T0, "1", PriorRun::Unknown).unwrap();
        s.note_splash_shown("v1").unwrap();
        s.note_reward_fired("first-run", T0).unwrap();
        s.note_clean_exit().unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), before, "an unreadable record is left exactly as it was");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_record_with_no_version_at_all_is_not_ours_and_is_left_alone() {
        let path = tmp_path("no-version");
        fs::write(&path, r#"{"installed_at":1,"starts":[1,2,3]}"#).unwrap();
        let before = fs::read_to_string(&path).unwrap();
        let mut s = LaunchStore::open(&path, T0).unwrap();
        assert!(!s.readable(), "a file with no version was not written by this schema");
        s.begin_run(T0, "1", PriorRun::Unknown).unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), before);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn an_unreadable_record_still_classifies_the_launch() {
        // The record refuses to write; the SPLASH still has to know what kind of start this
        // is. An unreadable file has no open marker, so it reads as fresh — the app opens
        // normally and shows its opening screen, which is the right failure.
        let path = tmp_path("unreadable-classify");
        fs::write(&path, "{ not json at all").unwrap();
        let mut s = LaunchStore::open(&path, T0).unwrap();
        assert!(!s.readable());
        assert_eq!(s.begin_run(T0, "1", PriorRun::Unknown).unwrap(), LaunchKind::Fresh);
        assert_eq!(s.next_window_kind(), LaunchKind::Fresh);
        assert_eq!(s.next_window_kind(), LaunchKind::SecondWindow);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_record_written_by_this_build_reads_back_as_readable() {
        // The positive probe for the three tests above: they would all pass on a store that
        // reported EVERY file unreadable.
        let path = tmp_path("readable-probe");
        {
            let mut s = LaunchStore::open(&path, T0).unwrap();
            s.begin_run(T0, "1", PriorRun::Unknown).unwrap();
        }
        let s = LaunchStore::open(&path, T0).unwrap();
        assert!(s.readable(), "our own file is readable");
        assert_eq!(s.schema_version(), LAUNCH_SCHEMA_VERSION);
        assert_eq!(s.counts(T0, PACIFIC).unwrap().total, 1);
        let _ = fs::remove_file(&path);
    }

    // ---- durability --------------------------------------------------------------------

    #[test]
    fn the_record_leaves_no_second_file_behind() {
        // The rename-based write uses a temporary. It must not survive the write, or a
        // half-written history is sitting on disk waiting to be found by something.
        let dir = std::env::temp_dir().join(format!(
            "richos-launch-solo-{}-{}",
            std::process::id(),
            crate::util::now_millis()
        ));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("launches.json");
        let mut s = LaunchStore::open(&path, T0).unwrap();
        s.begin_run(T0, "1", PriorRun::Unknown).unwrap();
        s.note_splash_shown("v2").unwrap();
        s.note_clean_exit().unwrap();
        let mut left: Vec<String> =
            fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        left.sort();
        assert_eq!(left, vec!["launches.json".to_string()], "one file, and only one");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_open_marker_is_what_a_crash_would_leave() {
        let path = tmp_path("marker");
        let mut s = LaunchStore::open(&path, T0).unwrap();
        assert!(!s.run_is_open(), "nothing open before a run begins");
        s.begin_run(T0, "1", PriorRun::Unknown).unwrap();
        assert!(s.run_is_open(), "a running app is marked open");
        s.note_clean_exit().unwrap();
        assert!(!s.run_is_open(), "a quit clears it");
        s.note_clean_exit().unwrap();
        assert!(!s.run_is_open(), "and clearing twice is fine");
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn a_hundred_launches_stay_in_order_and_cost_a_few_kilobytes() {
        let path = tmp_path("hundred");
        for i in 0..100u64 {
            let t = T0 + i * 86_400_000;
            let mut s = LaunchStore::open(&path, t).unwrap();
            s.begin_run(t, "1", PriorRun::Unknown).unwrap();
            s.note_clean_exit().unwrap();
        }
        let s = LaunchStore::open(&path, T0).unwrap();
        assert_eq!(s.starts().len(), 100);
        assert!(s.starts().windows(2).all(|w| w[0] < w[1]), "ascending");
        let bytes = fs::metadata(&path).unwrap().len();
        assert!(bytes < 4_096, "100 launches is {bytes} bytes — the log is cheap, as claimed");
        let _ = fs::remove_file(&path);
    }
}
