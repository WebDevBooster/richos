//! The MACHINERY JOURNAL — a separate, per-thread, day-sharded store.
//!
//! Design §2.1: `<app-data>/machinery/<thread_id>/<YYYY-MM-DD>.jsonl`, alongside
//! `conversation-ledger.jsonl` and `config.json` (`src-tauri/src/main.rs:123-126`,
//! `:157-158`). **Not loro** (it would poison the context compiler, it carries no truth
//! claim, and loro never deletes while machinery must be evictable — §2.1). **Not the
//! conversation ledger** (`ledger.rs:244-268` replays the whole file into memory at every
//! boot and holds it for the process lifetime; and `messages()` is one missing filter away
//! from putting tool output in the CEO's conversation — §2.1).
//!
//! ## Retention runs ALWAYS (§3.2)
//! Routing and retention are unconditional; a toggle would control rendering only. Making
//! retention conditional destroys the feature, because the requirement is to flip a thread
//! the CEO **already had**. (The toggle itself is not built here — §5 Phase 1 minus the
//! renderer; see the commit message.)
//!
//! ## §7.2 IS THE CEO'S QUESTION AND IS NOT ANSWERED HERE
//! *"How long do raw payloads survive?"* is open (open-items 1.4). What changed on
//! 2026-08-30 is only the COST of each answer: the window is [`RawRetention`], a value in
//! the config store beside the assertiveness dial and the techy toggle, and "14 days",
//! "90 days" and "forever" are now the same kind of act — a click — rather than one
//! default and two code changes. The shipping default is still [`RAW_RETENTION_DAYS`] /
//! [`RAW_MAX_TOTAL_BYTES`], byte for byte, and an install with no `raw_retention` key
//! behaves exactly as it did before the type existed.
//!
//! ## Durability posture: deliberately weaker than the ledger (§2.2)
//! Append + `flush`, **no `fsync`**. `ledger.rs:363-374` fsyncs crash-critical events
//! because losing a CEO word is unacceptable. Losing the last few machinery lines in a
//! crash costs a rendering detail; fsyncing thousands of records a day inside the
//! streaming hot path would buy nothing and cost turn latency. **Stated as a decision so
//! nobody "fixes" it later.** Corollary, also §2.2: a machinery write failure NEVER fails
//! a turn — the caller logs it and carries on. `spine.rs` makes a *ledger* write failure
//! terminal, correctly, because the ledger is truth. Machinery is not truth.
//!
//! ## The one place this file departs from §2.1's literal layout, and why
//! §2.4 requires two things that a single file per shard cannot both satisfy:
//!
//!   - **Tier A** (the normalized record) is *"retained for the life of the thread. Never
//!     evicted."*
//!   - **Tier B** (the raw `payload`) is a rolling window *"evicted oldest-shard-first (an
//!     `unlink`, by construction)"*.
//!
//! Unlink the one shard file and Tier A dies with Tier B. So each day shard is written as
//! a PAIR of sibling files:
//!
//! ```text
//! <app-data>/machinery/<thread_id>/2026-08-28.jsonl        Tier A — normalized, payload omitted, never evicted
//! <app-data>/machinery/<thread_id>/2026-08-28.raw.jsonl    Tier B — {machineryId, payload, truncated}, unlink-evictable
//! ```
//!
//! This is the minimal change that makes BOTH of §2.4's sentences literally true while
//! keeping eviction an `unlink` rather than a file rewrite — which is the property §2.4
//! chose the day shard for in the first place. It is an interpretation of a design that
//! did not spell out the second filename, and it is flagged as such rather than absorbed.
//! After eviction the record still renders — structure, title, status, paths, summary —
//! with `payload: None`. An honest degrade, never a silent blank.
//!
//! ## Per-thread directories and day shards (§2.1)
//! Retroactive rendering is *"read exactly this thread's machinery"*, which a per-thread
//! directory answers with an `ls`. Day shards make eviction an `unlink` and make "how big
//! is this?" answerable without parsing anything.
//!
//! ## Privacy (§2.5), stated plainly
//! This journal records every command Rich runs, every file path he touches, and a preview
//! of every output, per conversation, in plaintext, on the CEO's machine. It is strictly
//! more sensitive than the conversation ledger, which holds only what was *said*.
//! `ceo-private` by construction: it is not in loro, so the context compiler cannot select
//! it (`loro/lib/store.js:23-30` derives every source path from one root and does not know
//! this path exists) — a structural wall, not a policed one. Never injected into any
//! priming prompt at any visibility. Never leaves the device. Excluded from diagnostic
//! bundles by default. Eviction is a privacy control, not just a disk control.
//! **No secret redaction in v1** (§2.5), deliberately: the same bytes, unredacted, are
//! already written to plaintext by Claude Code itself next door, and a regex scrubber in
//! the streaming hot path would buy a false sense of safety. Sage flagged that argument
//! himself (§6.3) as the one most likely to be a rationalization; it is recorded here as
//! his call, not re-litigated as mine.
//! `delete_thread` exists so that §2.5 rule 6 — deleting a thread deletes its machinery —
//! is satisfiable by whoever adds a delete-thread command (there is none today).

use crate::machinery::MachineryRecord;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::fs::{File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};

/// §2.4 / §7.2: the raw payload window. 14 days OR 2 GB per install, whichever binds first.
///
/// **Still the SHIPPING DEFAULT, and no longer the only reachable answer.** These two are
/// what [`RawRetention::default`] is made of, and that default is what an install with no
/// `raw_retention` key in its config gets — so the behaviour on every existing machine is
/// byte-for-byte what it was. What changed is that the OTHER answers to §7.2 are now values
/// rather than edits: see [`RawRetention`].
pub const RAW_RETENTION_DAYS: u64 = 14;
/// 2 GiB.
pub const RAW_MAX_TOTAL_BYTES: u64 = 2 * 1024 * 1024 * 1024;

const MILLIS_PER_DAY: u64 = 86_400_000;

/// The token a "no limit" axis serializes as, in the config file and on the wire. Named
/// once so the Rust, the JSON on disk and the UI cannot drift into three spellings.
pub const FOREVER: &str = "forever";

// ===========================================================================================
// THE RAW WINDOW AS A VALUE (§7.2 — the CEO's open question, made answerable without a
// developer)
//
// §7.2 is *"how long do raw payloads survive?"* and it is HIS to answer. Until this type
// existed one of his possible answers — 14 days — was two `const`s and every other answer
// was a code change, which is not a neutral way to leave a question open: it quietly argues
// for the status quo. The point of this type is that "14 days", "90 days" and "forever" now
// cost exactly the same thing, which is a click.
//
// WHY "FOREVER" IS A VARIANT AND NOT A BIG NUMBER. `u64::MAX` as a sentinel would be a fact
// someone has to remember, and it is worse than that here: the old body computed
// `max_age_days * MILLIS_PER_DAY`, which for `u64::MAX` PANICS in a debug build and wraps in
// release — wrapping to a cutoff far in the future, i.e. to "delete everything". The one
// sentinel a person would reach for first is the one that deletes his record. So it is a
// variant, the multiply is saturating, and neither of those is decoration.
//
// TWO AXES, NOT ONE, AND NEITHER SUBSUMES THE OTHER. A day window bounds how far BACK the
// raw output goes; a byte ceiling bounds how much DISK it may cost. A quiet fortnight is 30
// MB and a loud one can be 20 GB, so the ceiling is the only thing standing between §2.4 and
// a full disk, and the window is the only thing that expresses "I do not want last quarter's
// terminal output on this machine". Each axis is therefore its own [`RetentionLimit`] — and
// "forever" is only honest when BOTH of them say it, which is why [`RawRetention::FOREVER`]
// exists as one named value rather than as an instruction to set two fields correctly.
// ===========================================================================================

/// One axis of the raw window. `Forever` is a VARIANT, never a magic number.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RetentionLimit {
    /// No limit on this axis. Nothing is ever evicted on account of it.
    Forever,
    /// A finite limit — days on the age axis, bytes on the size axis.
    ///
    /// `Of(0)` is a real, honoured instruction ("keep nothing older than today", "keep no
    /// bytes"), not a sentinel and not an error. It is reachable only by writing it into
    /// the config file deliberately: no surface offers it, and no unreadable value ever
    /// BECOMES it — see [`RetentionLimit::from_json`], where every unreadable value becomes
    /// `Forever` instead.
    Of(u64),
}

impl RetentionLimit {
    pub fn is_forever(&self) -> bool {
        matches!(self, RetentionLimit::Forever)
    }

    /// The finite value, or `None` for `Forever`.
    pub fn value(&self) -> Option<u64> {
        match self {
            RetentionLimit::Forever => None,
            RetentionLimit::Of(n) => Some(*n),
        }
    }

    /// Read one axis out of arbitrary JSON, **without ever failing**, and biased in every
    /// unreadable case toward KEEPING.
    ///
    /// This asymmetry is the whole safety argument of the setting. Eviction is an `unlink`:
    /// a retention value misread as a small number destroys the CEO's stored output and
    /// nothing announces it, while a retention value misread as "forever" costs disk he can
    /// reclaim by clicking the setting he was trying to set anyway. One failure mode is
    /// recoverable and the other is not, so `"fourteen"`, `-1`, `1.5`, `null`, `true` and
    /// `[]` all read as `Forever` rather than as anything that deletes.
    pub fn from_json(v: &Value) -> Self {
        match v {
            Value::String(s) if s.trim().eq_ignore_ascii_case(FOREVER) => RetentionLimit::Forever,
            // `as_u64` is `None` for a negative or fractional number — neither of which is a
            // limit anybody wrote on purpose, and both of which would otherwise have to be
            // clamped to SOMETHING. Clamping toward zero deletes; this does not.
            Value::Number(n) => n.as_u64().map(RetentionLimit::Of).unwrap_or(RetentionLimit::Forever),
            _ => RetentionLimit::Forever,
        }
    }
}

impl Serialize for RetentionLimit {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        match self {
            RetentionLimit::Forever => s.serialize_str(FOREVER),
            RetentionLimit::Of(n) => s.serialize_u64(*n),
        }
    }
}

impl<'de> Deserialize<'de> for RetentionLimit {
    /// Hand-written rather than derived, for one reason: a derived impl ERRORS on a value it
    /// does not recognize, and a serde error inside `config.json` fails the whole file, which
    /// degrades EVERY preference to its default — including this one, back to 14 days, back
    /// to deleting. Going through `Value` first means any well-formed JSON produces an
    /// answer, and [`RetentionLimit::from_json`] makes that answer `Forever`.
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(RetentionLimit::from_json(&Value::deserialize(d)?))
    }
}

/// The raw-payload window, both axes. §2.4's *"whichever binds first"*, as a value.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub struct RawRetention {
    /// How far back the raw output goes.
    pub age_days: RetentionLimit,
    /// How much disk it may cost, install-wide.
    pub total_bytes: RetentionLimit,
}

impl RawRetention {
    /// Keep everything. **Both** axes — a "forever" that left the byte ceiling in place
    /// would still delete his oldest output the day the install crossed 2 GB, which is not
    /// what the word means.
    pub const FOREVER: RawRetention = RawRetention {
        age_days: RetentionLimit::Forever,
        total_bytes: RetentionLimit::Forever,
    };

    pub fn of(age_days: u64, total_bytes: u64) -> Self {
        RawRetention {
            age_days: RetentionLimit::Of(age_days),
            total_bytes: RetentionLimit::Of(total_bytes),
        }
    }

    /// True only when NEITHER axis can evict.
    pub fn is_forever(&self) -> bool {
        self.age_days.is_forever() && self.total_bytes.is_forever()
    }

    /// Read the whole setting out of arbitrary JSON, without ever failing.
    ///
    /// Three shapes are understood, and everything else keeps data:
    ///
    /// - an object — `{"age_days": 14, "total_bytes": 2147483648}`. Both `snake_case` (what
    ///   this writes, matching the rest of `config.json`) and `camelCase` (what someone
    ///   copying the wire shape would type) are accepted, because a key spelling that misses
    ///   is a key that silently changes his retention.
    /// - the bare string `"forever"`, so the shortest thing a person is likely to type by
    ///   hand means what they meant.
    /// - anything else — a number, `null`, a list, a typo — is not a window anyone wrote on
    ///   purpose, and becomes [`Self::FOREVER`] rather than something that deletes.
    ///
    /// **An axis ABSENT from a present object is `Forever`, not the shipping default.** The
    /// absent-whole-key case is what carries the shipping default (`#[serde(default)]` in
    /// `config.rs`); once the object is there, `{"age_days": "forever"}` has to mean forever
    /// on the axis it names and no eviction on the one it does not, or "forever" would still
    /// quietly delete at 2 GB.
    pub fn from_json(v: &Value) -> Self {
        let Value::Object(map) = v else { return RawRetention::FOREVER };
        let axis = |snake: &str, camel: &str| {
            map.get(snake)
                .or_else(|| map.get(camel))
                .map(RetentionLimit::from_json)
                .unwrap_or(RetentionLimit::Forever)
        };
        RawRetention {
            age_days: axis("age_days", "ageDays"),
            total_bytes: axis("total_bytes", "totalBytes"),
        }
    }
}

impl Default for RawRetention {
    /// **The shipping default, and today's behaviour exactly**: [`RAW_RETENTION_DAYS`] and
    /// [`RAW_MAX_TOTAL_BYTES`], the same two constants `evict_raw` was called with before
    /// this type existed.
    fn default() -> Self {
        RawRetention::of(RAW_RETENTION_DAYS, RAW_MAX_TOTAL_BYTES)
    }
}

impl<'de> Deserialize<'de> for RawRetention {
    /// Hand-written for the same reason [`RetentionLimit`]'s is: a `raw_retention` key that
    /// is not the shape this expects must not fail the parse of `config.json` and take every
    /// other preference down with it — and must not, on the way, hand this one back to a
    /// default that deletes.
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(RawRetention::from_json(&Value::deserialize(d)?))
    }
}

/// WHY THERE IS NOTHING HERE — the four answers, kept apart on purpose.
///
/// The renderer this store was built for has to say something to the CEO when a thread
/// shows no machinery, and *"no machinery was recorded for this conversation"* and
/// *"this conversation had no machinery"* are different sentences. Only the first one is
/// honest, and it is only honest when it is TRUE — which [`MachineryJournal::read_thread`]
/// cannot tell you, because it returns an empty `Vec` for a thread that predates routing,
/// for a directory the OS refused to open, and for an install where retention was never
/// attached alike.
///
/// So the checked read distinguishes them, and the renderer says a different thing for
/// each. An empty affordance is a lie about the system; so is an empty pane where the
/// truth is "I could not read the file".
#[derive(Debug, Clone, PartialEq)]
pub enum ThreadMachinery {
    /// Records were read. Never empty — an empty result is [`Self::NothingRecorded`].
    Recorded(Vec<MachineryRecord>),
    /// The journal was readable and this thread has nothing in it. **The honest empty
    /// state, and the only one of the four that may render as "nothing was recorded for
    /// this conversation."** Every thread that ran before the routing commit lands here,
    /// which is the unavoidable cost of the drop that preceded it (§5) and is pinned by
    /// two existing tests.
    NothingRecorded,
    /// There is no machinery root at all: nothing on this install has ever been retained.
    /// Different from the above because it is a fact about the INSTALL, not the thread —
    /// a fresh machine, or a spine with no journal attached (`set_machinery_journal` is
    /// optional, and the headless spine runs without one).
    NotRetained,
    /// The store is there and the OS refused to read it. **Never reported as empty.**
    /// Carries the operator-facing reason; the CEO-facing sentence is the renderer's.
    Unreadable(String),
}

impl ThreadMachinery {
    /// The records, or an empty slice. For a caller that genuinely only wants rows —
    /// never for one that has to TELL the CEO why there are none.
    pub fn records(&self) -> &[MachineryRecord] {
        match self {
            ThreadMachinery::Recorded(v) => v,
            _ => &[],
        }
    }

    /// A stable wire tag for the four states.
    pub fn as_str(&self) -> &'static str {
        match self {
            ThreadMachinery::Recorded(_) => "recorded",
            ThreadMachinery::NothingRecorded => "nothing_recorded",
            ThreadMachinery::NotRetained => "not_retained",
            ThreadMachinery::Unreadable(_) => "unreadable",
        }
    }
}

/// The Tier-B sidecar line. Joined back to its Tier-A record by `machineryId`.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawLine {
    machinery_id: String,
    payload: Value,
    truncated: bool,
}

pub struct MachineryJournal {
    root: PathBuf,
}

impl MachineryJournal {
    /// `root` is `<app-data>/machinery`. Nothing is created until something is written.
    pub fn new(root: impl AsRef<Path>) -> Self {
        MachineryJournal { root: root.as_ref().to_path_buf() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn thread_dir(&self, thread_id: &str) -> PathBuf {
        self.root.join(thread_id)
    }

    /// Append one record. Tier A always; Tier B only when there is a payload to keep.
    ///
    /// Append + flush, NO fsync (§2.2). Returns `io::Result` so the caller can log a
    /// failure — but per §2.2 the caller must never fail the turn on it.
    pub fn append(&self, record: &MachineryRecord) -> std::io::Result<()> {
        let dir = self.thread_dir(&record.thread_id);
        std::fs::create_dir_all(&dir)?;
        let day = day_shard(record.at);

        // Tier A: the normalized record with the payload OMITTED. Never evicted.
        let mut tier_a = record.clone();
        tier_a.payload = None;
        let mut line = serde_json::to_string(&tier_a)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        line.push('\n');
        append_line(&dir.join(format!("{day}.jsonl")), &line)?;

        // Tier B: the raw payload, in its own unlink-evictable sibling.
        if let Some(payload) = record.payload.as_ref() {
            let raw = RawLine {
                machinery_id: record.machinery_id.clone(),
                payload: payload.clone(),
                truncated: record.truncated,
            };
            let mut line = serde_json::to_string(&raw)
                .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
            line.push('\n');
            append_line(&dir.join(format!("{day}.raw.jsonl")), &line)?;
        }
        Ok(())
    }

    /// Every record for one thread, in append order, with raw payloads re-attached where
    /// their Tier-B shard still exists. A record whose raw shard has been evicted comes
    /// back with `payload: None` — it still renders (§2.4).
    ///
    /// An unparsable line is SKIPPED, not fatal: this store is not truth (§2.2), and one
    /// torn line from a crash mid-append must not cost the CEO the rest of the day.
    pub fn read_thread(&self, thread_id: &str) -> Vec<MachineryRecord> {
        let dir = self.thread_dir(thread_id);
        let mut out = Vec::new();
        for day in self.day_shards(&dir) {
            let raws = read_raw_shard(&dir.join(format!("{day}.raw.jsonl")));
            let Ok(file) = File::open(dir.join(format!("{day}.jsonl"))) else { continue };
            for line in BufReader::new(file).lines().map_while(Result::ok) {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                let Ok(mut rec) = serde_json::from_str::<MachineryRecord>(line) else { continue };
                if let Some(raw) = raws.get(&rec.machinery_id) {
                    rec.payload = Some(raw.0.clone());
                    rec.truncated = raw.1;
                }
                out.push(rec);
            }
        }
        out
    }

    /// The rows a renderer would show for one thread: `read_thread` folded through
    /// `machinery::project` (§1.4 G2/G6), with `internal: true` records excluded — §1.5's
    /// rule that re-prime and rotation machinery is retained for debugging and **never**
    /// appears in a thread render.
    pub fn project_thread(&self, thread_id: &str) -> Vec<MachineryRecord> {
        let records = self.read_thread(thread_id).into_iter().filter(|r| !r.internal).collect();
        crate::machinery::project(records)
    }

    /// [`Self::read_thread`], with the reason for an empty answer kept rather than
    /// thrown away. See [`ThreadMachinery`] for why the four states are not one.
    ///
    /// An unparsable LINE is still skipped, exactly as `read_thread` skips it — a torn
    /// line from a crash mid-append is not "the store is unreadable" and must not cost
    /// the CEO the rest of the day (§2.2, this store is not truth). An unreadable
    /// DIRECTORY or an unopenable SHARD is a different thing and is reported.
    pub fn read_thread_checked(&self, thread_id: &str) -> ThreadMachinery {
        // The root first: "this install has never retained anything" is a fact about the
        // machine and must not be reported as a fact about the thread.
        if let Err(e) = std::fs::read_dir(&self.root) {
            return match e.kind() {
                std::io::ErrorKind::NotFound => ThreadMachinery::NotRetained,
                _ => ThreadMachinery::Unreadable(format!("{}: {e}", self.root.display())),
            };
        }
        let dir = self.thread_dir(thread_id);
        let days = match std::fs::read_dir(&dir) {
            Ok(_) => self.day_shards(&dir),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return ThreadMachinery::NothingRecorded
            }
            Err(e) => return ThreadMachinery::Unreadable(format!("{}: {e}", dir.display())),
        };

        let mut out = Vec::new();
        for day in days {
            let raws = read_raw_shard(&dir.join(format!("{day}.raw.jsonl")));
            let path = dir.join(format!("{day}.jsonl"));
            let file = match File::open(&path) {
                Ok(f) => f,
                // The shard was listed one syscall ago, so a NotFound here is a shard that
                // vanished under us (an eviction, a manual delete) — not a reason to
                // refuse the rest of the thread.
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
                Err(e) => return ThreadMachinery::Unreadable(format!("{}: {e}", path.display())),
            };
            for line in BufReader::new(file).lines().map_while(Result::ok) {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                let Ok(mut rec) = serde_json::from_str::<MachineryRecord>(line) else { continue };
                if let Some(raw) = raws.get(&rec.machinery_id) {
                    rec.payload = Some(raw.0.clone());
                    rec.truncated = raw.1;
                }
                out.push(rec);
            }
        }
        if out.is_empty() {
            // A thread directory that exists but holds nothing readable — an empty shard,
            // or a day of torn lines. The store answered; there is nothing in it.
            return ThreadMachinery::NothingRecorded;
        }
        ThreadMachinery::Recorded(out)
    }

    /// [`Self::project_thread`], checked. `internal: true` records are excluded here for
    /// the same §1.5 reason — and note the consequence, which is correct and easy to
    /// misread: a thread whose ONLY machinery is re-prime traffic reports
    /// [`ThreadMachinery::NothingRecorded`], because from a thread view's point of view
    /// nothing WAS recorded. Rotation machinery is retained for debugging and must never
    /// surface, not even as a count.
    pub fn project_thread_checked(&self, thread_id: &str) -> ThreadMachinery {
        match self.read_thread_checked(thread_id) {
            ThreadMachinery::Recorded(records) => {
                let visible: Vec<MachineryRecord> = records.into_iter().filter(|r| !r.internal).collect();
                if visible.is_empty() {
                    return ThreadMachinery::NothingRecorded;
                }
                ThreadMachinery::Recorded(crate::machinery::project(visible))
            }
            other => other,
        }
    }

    /// The Tier-B raw payload for ONE record, looked up by `machineryId` (§2.4's raw
    /// pane), without materializing every payload in the thread.
    ///
    /// `Ok(None)` means **the raw window has passed over this record**: the normalized
    /// record still renders — structure, title, status, paths, summary — and the raw pane
    /// says so. An honest degrade, never a silent blank (§2.4).
    ///
    /// **Window-agnostic on purpose.** §7.2 (how long raw payloads survive) is the CEO's
    /// open question, and nothing here reads the window: this returns what is on disk. Any
    /// answer — 14 days, 2 GB, or forever — changes `evict_raw`'s arguments and changes
    /// nothing about this function or about what the CEO sees.
    pub fn raw_payload(&self, thread_id: &str, machinery_id: &str) -> Result<Option<(Value, bool)>, String> {
        let dir = self.thread_dir(thread_id);
        let days = match std::fs::read_dir(&dir) {
            Ok(_) => self.day_shards(&dir),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("{}: {e}", dir.display())),
        };
        for day in days {
            let raws = read_raw_shard(&dir.join(format!("{day}.raw.jsonl")));
            if let Some(hit) = raws.get(machinery_id) {
                return Ok(Some((hit.0.clone(), hit.1)));
            }
        }
        Ok(None)
    }

    /// Day shards present for a thread, ascending. `YYYY-MM-DD` sorts lexicographically,
    /// which is why the shard name is that shape and not an epoch.
    fn day_shards(&self, dir: &Path) -> Vec<String> {
        let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
        let mut days: Vec<String> = entries
            .filter_map(|e| e.ok())
            .filter_map(|e| e.file_name().into_string().ok())
            .filter(|n| n.ends_with(".jsonl") && !n.ends_with(".raw.jsonl"))
            .map(|n| n.trim_end_matches(".jsonl").to_string())
            .collect();
        days.sort();
        days
    }

    /// §2.5 rule 6: deleting a thread deletes its machinery. No delete-thread command
    /// exists today (`main.rs:168-190`); this is here so that whoever adds one has the
    /// primitive and "delete" can mean delete.
    pub fn delete_thread(&self, thread_id: &str) -> std::io::Result<()> {
        let dir = self.thread_dir(thread_id);
        if dir.exists() {
            std::fs::remove_dir_all(dir)?;
        }
        Ok(())
    }

    /// Tier-B eviction (§2.4): raw payloads older than `max_age_days`, then oldest-first
    /// until the total raw bytes fit `max_total_bytes`. Whichever binds first.
    ///
    /// Every step is an `unlink` of a `*.raw.jsonl` sibling — Tier A is never touched, so
    /// an evicted day still renders its structure, titles, statuses, paths and summaries.
    /// Returns the number of raw shards removed.
    ///
    /// **The two-`u64` form, kept.** It is now a thin call into
    /// [`Self::evict_raw_within`], deliberately: the tests that pinned this function's
    /// behaviour before the window became a setting still call it, unchanged, with
    /// [`RAW_RETENTION_DAYS`] and [`RAW_MAX_TOTAL_BYTES`] — so they now prove that the
    /// shipping default runs the NEW path to the OLD answer, which is a stronger claim
    /// than any assertion I could write about it.
    pub fn evict_raw(&self, now_ms: u64, max_age_days: u64, max_total_bytes: u64) -> usize {
        self.evict_raw_within(now_ms, RawRetention::of(max_age_days, max_total_bytes))
    }

    /// Tier-B eviction against the CEO's configured window ([`RawRetention`]).
    ///
    /// `RetentionLimit::Forever` on an axis means that axis evicts NOTHING — it is not a
    /// large number, and there is no arithmetic anywhere in this function that a large
    /// number would have to survive. The one multiplication left is saturating, so even a
    /// hand-written `{"age_days": 18446744073709551615}` produces a cutoff of `1970-01-01`
    /// (which no shard sorts before) instead of the debug-build panic / release-build wrap
    /// to "delete everything" that `days * MILLIS_PER_DAY` used to give.
    pub fn evict_raw_within(&self, now_ms: u64, retention: RawRetention) -> usize {
        let mut shards = self.raw_shards();
        if shards.is_empty() {
            return 0;
        }
        // Oldest first — the day string sorts chronologically.
        shards.sort_by(|a, b| a.0.cmp(&b.0));

        let cutoff = match retention.age_days {
            RetentionLimit::Forever => None,
            RetentionLimit::Of(days) => {
                Some(day_shard(now_ms.saturating_sub(days.saturating_mul(MILLIS_PER_DAY))))
            }
        };

        let mut removed = 0usize;
        let mut kept: Vec<(String, PathBuf, u64)> = Vec::new();
        for (day, path, size) in shards {
            let too_old = match &cutoff {
                Some(c) => &day < c,
                None => false,
            };
            if too_old {
                if std::fs::remove_file(&path).is_ok() {
                    removed += 1;
                }
            } else {
                kept.push((day, path, size));
            }
        }

        let RetentionLimit::Of(max_total_bytes) = retention.total_bytes else {
            return removed;
        };
        let mut total: u64 = kept.iter().map(|k| k.2).sum();
        let mut i = 0;
        while total > max_total_bytes && i < kept.len() {
            if std::fs::remove_file(&kept[i].1).is_ok() {
                total = total.saturating_sub(kept[i].2);
                removed += 1;
            }
            i += 1;
        }
        removed
    }

    /// Total bytes of retained raw payloads — answerable without parsing anything, which
    /// is the other reason §2.1 chose day shards.
    pub fn raw_bytes(&self) -> u64 {
        self.raw_shards().iter().map(|s| s.2).sum()
    }

    /// (day, path, size) for every Tier-B shard under every thread.
    fn raw_shards(&self) -> Vec<(String, PathBuf, u64)> {
        let mut out = Vec::new();
        let Ok(threads) = std::fs::read_dir(&self.root) else { return out };
        for t in threads.filter_map(|e| e.ok()) {
            let Ok(files) = std::fs::read_dir(t.path()) else { continue };
            for f in files.filter_map(|e| e.ok()) {
                let Ok(name) = f.file_name().into_string() else { continue };
                if !name.ends_with(".raw.jsonl") {
                    continue;
                }
                let size = f.metadata().map(|m| m.len()).unwrap_or(0);
                out.push((name.trim_end_matches(".raw.jsonl").to_string(), f.path(), size));
            }
        }
        out
    }
}

fn append_line(path: &Path, line: &str) -> std::io::Result<()> {
    let mut f = OpenOptions::new().create(true).append(true).open(path)?;
    f.write_all(line.as_bytes())?;
    // flush, NOT sync_data — §2.2, deliberately.
    f.flush()
}

fn read_raw_shard(path: &Path) -> std::collections::HashMap<String, (Value, bool)> {
    let mut map = std::collections::HashMap::new();
    let Ok(file) = File::open(path) else { return map };
    for line in BufReader::new(file).lines().map_while(Result::ok) {
        if let Ok(r) = serde_json::from_str::<RawLine>(line.trim()) {
            map.insert(r.machinery_id, (r.payload, r.truncated));
        }
    }
    map
}

/// `YYYY-MM-DD` (UTC) for an epoch-millis label.
///
/// Written out rather than pulled from `chrono` on purpose: `richos-core` is deliberately
/// native-dependency-free and fast to test (`app/Cargo.toml`, `app/README.md`), and this is
/// twelve lines of well-known arithmetic. Howard Hinnant's `civil_from_days`, verified in
/// the tests below against epoch 0, both sides of a day boundary, a leap day, and 2100
/// (a non-leap century, the case a naive `%4` gets wrong).
pub fn day_shard(millis: u64) -> String {
    let days = (millis / MILLIS_PER_DAY) as i64;
    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as i64; // [0, 146096]
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365; // [0, 399]
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100); // [0, 365]
    let mp = (5 * doy + 2) / 153; // [0, 11]
    let d = doy - (153 * mp + 2) / 5 + 1; // [1, 31]
    let m = if mp < 10 { mp + 3 } else { mp - 9 }; // [1, 12]
    let year = if m <= 2 { y + 1 } else { y };
    format!("{year:04}-{m:02}-{d:02}")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::machinery::{MachineryKind, MachineryRecord, ToolStatus};
    use serde_json::json;

    fn tmp() -> PathBuf {
        std::env::temp_dir().join(format!("richos-journal-{}", crate::util::new_id("t")))
    }

    fn rec(thread: &str, turn: Option<&str>, seq: u64, at: u64, payload_size: usize) -> MachineryRecord {
        let u = json!({"sessionUpdate":"tool_call","toolCallId":format!("t{seq}"),
                       "status":"pending","title":"Terminal","rawOutput":"x".repeat(payload_size)});
        let mut r = MachineryRecord::from_acp_update(&u, "sess", seq).unwrap().stamp(thread, turn, false);
        r.at = at;
        r
    }

    // ---- the four honest states (ThreadMachinery) --------------------------------

    #[test]
    fn an_install_that_has_never_retained_anything_says_so_and_does_not_say_empty() {
        // A fact about the INSTALL, not about the thread. `read_thread` returns [] here
        // and so cannot tell the renderer which sentence to say.
        let root = tmp();
        let j = MachineryJournal::new(&root);
        assert!(!root.exists(), "nothing written yet");
        assert_eq!(j.read_thread_checked("thr_1"), ThreadMachinery::NotRetained);
        assert_eq!(j.read_thread_checked("thr_1").as_str(), "not_retained");
        assert_eq!(j.project_thread_checked("thr_1"), ThreadMachinery::NotRetained);
    }

    #[test]
    fn a_thread_from_before_the_routing_commit_is_nothing_recorded_not_not_retained() {
        // THE state the renderer must get right: the journal exists because OTHER threads
        // ran, and this one predates routing. "No machinery was recorded for this
        // conversation" is true here and only here.
        let root = tmp();
        let j = MachineryJournal::new(&root);
        j.append(&rec("thr_new", Some("turn_1"), 1, 1_756_425_600_000, 8)).unwrap();

        assert!(matches!(j.read_thread_checked("thr_new"), ThreadMachinery::Recorded(v) if v.len() == 1));
        assert_eq!(j.read_thread_checked("thr_old"), ThreadMachinery::NothingRecorded);
        assert_eq!(j.project_thread_checked("thr_old").as_str(), "nothing_recorded");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_directory_the_os_refuses_is_unreadable_and_is_never_reported_as_empty() {
        // The fourth state, and the one that is easiest to serve as a blank pane. Proven
        // with a REAL chmod 000, not a mocked error: `read_thread` returns [] for this
        // directory today, which would render as "nothing was recorded" over a thread
        // whose machinery is sitting on disk one permission bit away.
        use std::os::unix::fs::PermissionsExt;
        let root = tmp();
        let j = MachineryJournal::new(&root);
        j.append(&rec("thr_locked", Some("turn_1"), 1, 1_756_425_600_000, 8)).unwrap();
        let dir = root.join("thr_locked");
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o000)).unwrap();

        // The unchecked read cannot tell the difference — that is the defect this exists
        // to fix, asserted rather than described.
        assert!(j.read_thread("thr_locked").is_empty());

        let checked = j.read_thread_checked("thr_locked");
        assert_eq!(checked.as_str(), "unreadable");
        match &checked {
            ThreadMachinery::Unreadable(why) => {
                assert!(why.contains("thr_locked"), "the reason names the path: {why}");
                assert!(!why.is_empty());
            }
            other => panic!("expected Unreadable, got {other:?}"),
        }
        assert!(checked.records().is_empty(), "and it carries no rows to mistake for an answer");

        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o755)).unwrap();
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_thread_whose_only_machinery_is_reprime_traffic_reports_nothing_recorded() {
        // §1.5: rotation machinery is retained for debugging and NEVER surfaces in a
        // thread view — not even as a count, and not as a row the renderer then hides.
        let root = tmp();
        let j = MachineryJournal::new(&root);
        let mut internal = rec("thr_1", None, 1, 1_756_425_600_000, 8);
        internal.internal = true;
        j.append(&internal).unwrap();

        assert!(matches!(j.read_thread_checked("thr_1"), ThreadMachinery::Recorded(v) if v.len() == 1),
                "the raw read still sees it — it IS retained");
        assert_eq!(j.project_thread_checked("thr_1"), ThreadMachinery::NothingRecorded,
                   "but a thread view has nothing to show, and says the honest thing");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_torn_line_is_skipped_not_reported_as_an_unreadable_store() {
        // §2.2: this store is not truth. One torn line from a crash mid-append must not
        // cost the CEO the rest of the day, and must not be dressed up as an IO failure.
        let root = tmp();
        let j = MachineryJournal::new(&root);
        j.append(&rec("thr_1", Some("turn_1"), 1, 1_756_425_600_000, 8)).unwrap();
        let shard = root.join("thr_1").join(format!("{}.jsonl", day_shard(1_756_425_600_000)));
        let mut f = OpenOptions::new().append(true).open(&shard).unwrap();
        f.write_all(b"{\"machineryId\":\"mach_tor").unwrap();
        drop(f);

        match j.read_thread_checked("thr_1") {
            ThreadMachinery::Recorded(v) => assert_eq!(v.len(), 1, "the intact record survives"),
            other => panic!("expected Recorded, got {other:?}"),
        }
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_empty_shard_file_is_nothing_recorded_not_recorded_with_zero_rows() {
        // `Recorded(vec![])` would be a fifth state meaning the same as the second, and a
        // renderer would eventually branch on the wrong one. It cannot be constructed.
        let root = tmp();
        std::fs::create_dir_all(root.join("thr_1")).unwrap();
        std::fs::write(root.join("thr_1").join("2026-08-30.jsonl"), "").unwrap();
        let j = MachineryJournal::new(&root);
        assert_eq!(j.read_thread_checked("thr_1"), ThreadMachinery::NothingRecorded);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn the_raw_pane_can_tell_retained_from_evicted_without_knowing_the_window() {
        // §2.4's honest degrade, and §7.2's shape: `raw_payload` reads what is on disk and
        // never consults the retention window, so 14 days, 2 GB or forever all produce the
        // same two answers here — the record, or "no longer retained".
        let root = tmp();
        let j = MachineryJournal::new(&root);
        let at = 1_756_425_600_000;
        let r = rec("thr_1", Some("turn_1"), 1, at, 8);
        let id = r.machinery_id.clone();
        j.append(&r).unwrap();

        let got = j.raw_payload("thr_1", &id).unwrap();
        assert!(got.is_some(), "retained while the Tier-B sibling is there");
        assert_eq!(got.unwrap().1, false, "and not truncated at 8 bytes");

        // Evict exactly the way `evict_raw` does: unlink the sibling. Tier A is untouched.
        std::fs::remove_file(root.join("thr_1").join(format!("{}.raw.jsonl", day_shard(at)))).unwrap();
        assert_eq!(j.raw_payload("thr_1", &id).unwrap(), None, "gone, and said so");
        match j.read_thread_checked("thr_1") {
            ThreadMachinery::Recorded(v) => {
                assert_eq!(v.len(), 1, "the normalized record still renders");
                assert_eq!(v[0].payload, None, "with no raw half");
                assert_eq!(v[0].title, "Terminal", "structure, title and status survive");
                assert_eq!(v[0].status, Some(ToolStatus::Pending));
            }
            other => panic!("expected Recorded, got {other:?}"),
        }
        assert_eq!(j.raw_payload("thr_never_existed", &id).unwrap(), None);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn day_shard_matches_utc_calendar_dates() {
        // Check values computed independently (python datetime, UTC).
        assert_eq!(day_shard(0), "1970-01-01");
        assert_eq!(day_shard(86_399_999), "1970-01-01", "last millisecond of the day");
        assert_eq!(day_shard(86_400_000), "1970-01-02", "first millisecond of the next");
        assert_eq!(day_shard(951_782_400_000), "2000-02-29", "a leap day");
        assert_eq!(day_shard(1_767_225_599_000), "2025-12-31");
        assert_eq!(day_shard(1_756_425_600_000), "2025-08-29");
        assert_eq!(day_shard(4_102_444_800_000), "2100-01-01", "2100 is NOT a leap year");
    }

    #[test]
    fn day_shard_names_sort_chronologically_as_strings() {
        // The property eviction depends on — no date parsing anywhere in `evict_raw`.
        let mut days = vec![day_shard(1_767_225_599_000), day_shard(0), day_shard(951_782_400_000)];
        days.sort();
        assert_eq!(days, vec!["1970-01-01", "2000-02-29", "2025-12-31"]);
    }

    #[test]
    fn a_record_survives_a_write_read_round_trip() {
        let root = tmp();
        let j = MachineryJournal::new(&root);
        let r = rec("thr_a", Some("turn_1"), 0, 1_756_425_600_000, 10);
        j.append(&r).unwrap();
        let back = j.read_thread("thr_a");
        assert_eq!(back.len(), 1);
        assert_eq!(back[0], r, "including the raw payload, re-joined from the Tier-B sidecar");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn the_shard_is_a_pair_of_files_and_tier_a_omits_the_payload() {
        let root = tmp();
        let j = MachineryJournal::new(&root);
        j.append(&rec("thr_a", Some("t"), 0, 1_756_425_600_000, 50)).unwrap();
        let dir = root.join("thr_a");
        let tier_a = std::fs::read_to_string(dir.join("2025-08-29.jsonl")).unwrap();
        let tier_b = std::fs::read_to_string(dir.join("2025-08-29.raw.jsonl")).unwrap();
        assert!(!tier_a.contains("rawOutput"), "Tier A must not carry the raw payload");
        assert!(tier_a.contains("\"title\":\"Terminal\""));
        assert!(tier_b.contains("rawOutput"));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn one_thread_is_one_directory_and_threads_never_bleed_into_each_other() {
        let root = tmp();
        let j = MachineryJournal::new(&root);
        j.append(&rec("thr_a", Some("t"), 0, 1_756_425_600_000, 4)).unwrap();
        j.append(&rec("thr_b", Some("t"), 1, 1_756_425_600_000, 4)).unwrap();
        assert_eq!(j.read_thread("thr_a").len(), 1);
        assert_eq!(j.read_thread("thr_b").len(), 1);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_thread_with_no_machinery_reads_back_empty_and_never_panics() {
        // THE retroactivity answer for every thread that ran BEFORE this commit: an empty
        // list — the honest empty state — not a crash and not an error.
        let j = MachineryJournal::new(tmp());
        assert!(j.read_thread("thr_from_last_week").is_empty());
        assert!(j.project_thread("thr_from_last_week").is_empty());
    }

    #[test]
    fn a_torn_line_is_skipped_not_fatal() {
        let root = tmp();
        let j = MachineryJournal::new(&root);
        j.append(&rec("thr_a", Some("t"), 0, 1_756_425_600_000, 4)).unwrap();
        let shard = root.join("thr_a").join("2025-08-29.jsonl");
        let mut f = OpenOptions::new().append(true).open(&shard).unwrap();
        f.write_all(b"{\"machineryId\": \"mach_tor\n").unwrap();
        drop(f);
        j.append(&rec("thr_a", Some("t"), 1, 1_756_425_600_000, 4)).unwrap();
        assert_eq!(j.read_thread("thr_a").len(), 2, "the torn line is skipped, the rest survives");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn records_span_day_shards_and_read_back_in_order() {
        let root = tmp();
        let j = MachineryJournal::new(&root);
        j.append(&rec("thr_a", Some("t"), 0, 1_756_425_600_000, 4)).unwrap(); // 2025-08-29
        j.append(&rec("thr_a", Some("t"), 1, 1_756_425_600_000 + MILLIS_PER_DAY, 4)).unwrap(); // 08-30
        let back = j.read_thread("thr_a");
        assert_eq!(back.len(), 2);
        assert_eq!(back[0].seq, 0);
        assert_eq!(back[1].seq, 1);
        assert!(root.join("thr_a").join("2025-08-30.jsonl").exists());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn evicting_a_raw_shard_keeps_the_record_and_only_drops_the_payload() {
        // §2.4's honest degrade: after eviction the record still renders — structure,
        // title, status, paths, summary — and only the raw pane is gone.
        let root = tmp();
        let j = MachineryJournal::new(&root);
        let old = 1_756_425_600_000; // 2025-08-29
        let now = old + 30 * MILLIS_PER_DAY;
        j.append(&rec("thr_a", Some("t"), 0, old, 100)).unwrap();
        assert!(j.read_thread("thr_a")[0].payload.is_some());

        let removed = j.evict_raw(now, RAW_RETENTION_DAYS, RAW_MAX_TOTAL_BYTES);
        assert_eq!(removed, 1);
        assert!(!root.join("thr_a").join("2025-08-29.raw.jsonl").exists());
        assert!(root.join("thr_a").join("2025-08-29.jsonl").exists(), "Tier A is NEVER evicted");

        let back = j.read_thread("thr_a");
        assert_eq!(back.len(), 1, "the record survives its payload");
        assert!(back[0].payload.is_none());
        assert_eq!(back[0].title, "Terminal");
        assert_eq!(back[0].status, Some(ToolStatus::Pending));
        assert_eq!(back[0].kind, MachineryKind::ToolCall);
        assert!(back[0].summary.is_some(), "the bounded summary is Tier A and survives");
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn a_raw_shard_inside_the_window_is_not_evicted() {
        let root = tmp();
        let j = MachineryJournal::new(&root);
        let at = 1_756_425_600_000;
        j.append(&rec("thr_a", Some("t"), 0, at, 100)).unwrap();
        // 13 days later: inside the 14-day window.
        assert_eq!(j.evict_raw(at + 13 * MILLIS_PER_DAY, RAW_RETENTION_DAYS, RAW_MAX_TOTAL_BYTES), 0);
        assert!(j.read_thread("thr_a")[0].payload.is_some());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn the_byte_ceiling_binds_before_the_age_window_when_it_is_smaller() {
        // "14 days OR 2 GB per install, whichever binds first" — proved with a tiny
        // ceiling rather than 2 GB of test fixtures.
        let root = tmp();
        let j = MachineryJournal::new(&root);
        let at = 1_756_425_600_000;
        j.append(&rec("thr_a", Some("t"), 0, at, 200)).unwrap();
        j.append(&rec("thr_a", Some("t"), 1, at + MILLIS_PER_DAY, 200)).unwrap();
        let before = j.raw_bytes();
        assert!(before > 0);
        // Everything is inside the age window; only the ceiling can bind.
        let removed = j.evict_raw(at + MILLIS_PER_DAY, RAW_RETENTION_DAYS, 100);
        assert!(removed >= 1, "the ceiling evicted oldest-first");
        assert!(j.raw_bytes() < before);
        assert_eq!(j.read_thread("thr_a").len(), 2, "every Tier-A record still there");
        std::fs::remove_dir_all(&root).ok();
    }

    // ---- §7.2: the window as a SETTING -------------------------------------------------

    /// A journal with raw payloads on six known days, `day 0` being the oldest. Returns the
    /// root and the "now" that makes the newest shard today, so every test below can speak
    /// in ages rather than in epochs.
    fn aged_journal(days: &[u64]) -> (PathBuf, MachineryJournal, u64) {
        let root = tmp();
        let j = MachineryJournal::new(&root);
        let newest = 1_756_425_600_000; // 2025-08-29, the day the other tests use
        for (i, age) in days.iter().enumerate() {
            let at = newest - age * MILLIS_PER_DAY;
            j.append(&rec("thr_a", Some("t"), i as u64, at, 100)).unwrap();
        }
        (root.clone(), MachineryJournal::new(&root), newest)
    }

    /// How many day shards still carry their raw payload, and how many records still render.
    fn survivors(root: &Path, j: &MachineryJournal) -> (usize, usize) {
        let raw = std::fs::read_dir(root.join("thr_a"))
            .map(|d| {
                d.filter_map(|e| e.ok())
                    .filter(|e| e.file_name().to_string_lossy().ends_with(".raw.jsonl"))
                    .count()
            })
            .unwrap_or(0);
        let with_payload = j.read_thread("thr_a").iter().filter(|r| r.payload.is_some()).count();
        (raw, with_payload)
    }

    #[test]
    fn the_shipping_default_is_exactly_the_two_constants_it_replaced() {
        // The claim the whole change stands on: an install with no `raw_retention` key
        // behaves as it did yesterday. Proven by running BOTH forms over two identical
        // journals and comparing what survived, not by asserting that the code looks the
        // same. (The rest of this file's eviction tests still call the two-`u64` form with
        // the constants, so they now exercise the new path to the old answer.)
        assert_eq!(RawRetention::default(), RawRetention::of(RAW_RETENTION_DAYS, RAW_MAX_TOTAL_BYTES));

        let ages = [40, 20, 15, 13, 1, 0];
        let (root_a, ja, now) = aged_journal(&ages);
        let (root_b, jb, _) = aged_journal(&ages);
        let old_way = ja.evict_raw(now, RAW_RETENTION_DAYS, RAW_MAX_TOTAL_BYTES);
        let new_way = jb.evict_raw_within(now, RawRetention::default());
        assert_eq!(old_way, new_way, "the same number of shards removed");
        assert_eq!(survivors(&root_a, &ja), survivors(&root_b, &jb), "and the same ones left");
        assert_eq!(old_way, 3, "40, 20 and 15 days old are past a 14-day window; 13, 1 and 0 are not");
        let _ = std::fs::remove_dir_all(&root_a);
        let _ = std::fs::remove_dir_all(&root_b);
    }

    #[test]
    fn the_survival_counts_at_four_windows() {
        // THE OBSERVABLE CRITERION, in one test: the same journal — raw payloads on six
        // known days — evicted at four different settings, reported as counts.
        //
        // Tier A is never touched by any of them, which is the sentence under every row:
        // the record still renders at every setting; only the stored output goes.
        let ages = [40, 20, 15, 13, 1, 0];
        let mut table = Vec::new();
        for (label, retention, expect_raw) in [
            ("forever", RawRetention::FOREVER, 6usize),
            ("90 days", RawRetention::of(90, RAW_MAX_TOTAL_BYTES), 6),
            ("14 days (the shipping default)", RawRetention::default(), 3),
            ("0 days", RawRetention::of(0, RAW_MAX_TOTAL_BYTES), 1),
        ] {
            let (root, j, now) = aged_journal(&ages);
            let records_before = j.read_thread("thr_a").len();
            let removed = j.evict_raw_within(now, retention);
            let (raw_shards, with_payload) = survivors(&root, &j);
            assert_eq!(records_before, 6, "six records went in");
            assert_eq!(j.read_thread("thr_a").len(), 6, "and six still render at {label}");
            assert_eq!(raw_shards, expect_raw, "raw shards surviving at {label}");
            assert_eq!(with_payload, expect_raw, "and each surviving shard re-attaches its payload");
            assert_eq!(removed, 6 - expect_raw, "removed count agrees with what is gone at {label}");
            table.push(format!("{label:>30}: {raw_shards}/6 raw shards kept, 6/6 records still render"));
            let _ = std::fs::remove_dir_all(&root);
        }
        // Printed so the numbers in the handoff are the numbers the test produced.
        for row in &table {
            println!("{row}");
        }
    }

    #[test]
    fn forever_evicts_nothing_on_either_axis_including_a_journal_over_the_old_ceiling() {
        // "Forever" that left the 2 GB ceiling in place would still delete his oldest
        // output the day the install crossed it, which is not what the word means. Proven
        // with a tiny ceiling standing in for 2 GB: under `FOREVER` there is no ceiling at
        // all, so nothing goes even though the journal is far over the one it replaced.
        let (root, j, now) = aged_journal(&[400, 200, 100, 3, 0]);
        assert!(j.raw_bytes() > 100, "the fixture is over the stand-in ceiling");
        assert_eq!(j.evict_raw_within(now, RawRetention::FOREVER), 0, "nothing, at any age");
        assert_eq!(survivors(&root, &j), (5, 5));
        // ...and the axes really are independent: a forever AGE with a finite ceiling still
        // evicts by size, oldest first.
        let size_capped = RawRetention { age_days: RetentionLimit::Forever, total_bytes: RetentionLimit::Of(100) };
        assert!(j.evict_raw_within(now, size_capped) >= 1, "the ceiling binds on its own");
        assert_eq!(j.read_thread("thr_a").len(), 5, "and Tier A is untouched by it");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn zero_days_is_an_honoured_instruction_and_keeps_today() {
        // The bottom of the dial. `Of(0)` is reachable only by writing it into the file on
        // purpose — no unreadable value becomes it (the test below) and no surface offers
        // it — and when it IS written it means what it says: nothing older than today.
        let (root, j, now) = aged_journal(&[2, 1, 0]);
        assert_eq!(j.evict_raw_within(now, RawRetention::of(0, RAW_MAX_TOTAL_BYTES)), 2);
        assert_eq!(survivors(&root, &j), (1, 1), "today's shard survives a zero-day window");
        assert_eq!(j.read_thread("thr_a").len(), 3, "and all three records still render");
        // A zero BYTE ceiling is the other end of the same instruction, and it is the one
        // that empties the store — still without touching a single Tier-A record.
        assert_eq!(j.evict_raw_within(now, RawRetention::of(0, 0)), 1);
        assert_eq!(survivors(&root, &j), (0, 0));
        assert_eq!(j.read_thread("thr_a").len(), 3, "three records, no payloads");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_window_too_large_to_multiply_keeps_everything_instead_of_wrapping_to_delete_everything() {
        // The sentinel hazard, run rather than argued. `u64::MAX` is the first thing anyone
        // reaches for to mean "forever", and the old body's `max_age_days * MILLIS_PER_DAY`
        // panics on it in a debug build and wraps in release — wrapping to a cutoff far in
        // the FUTURE, i.e. to deleting the lot. Saturating, it becomes 1970-01-01, which no
        // shard sorts before.
        let (root, j, now) = aged_journal(&[900, 30, 0]);
        assert_eq!(j.evict_raw_within(now, RawRetention::of(u64::MAX, u64::MAX)), 0);
        assert_eq!(survivors(&root, &j), (3, 3));
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn an_unreadable_window_keeps_data_and_never_becomes_a_number_that_deletes() {
        // THE FAILURE MODE THAT MATTERS. Eviction is an `unlink` and nothing announces it,
        // so every value this cannot read has to mean KEEP. A wrong "forever" costs disk he
        // can reclaim by clicking the setting; a wrong "0" costs a record that is gone.
        for bad in [
            json!("fourteen"),
            json!("14 days"),
            json!(-1),
            json!(1.5),
            json!(null),
            json!(true),
            json!([14]),
            json!({"days": 14}),
        ] {
            assert_eq!(RetentionLimit::from_json(&bad), RetentionLimit::Forever, "{bad}");
        }
        // The whole-setting shapes, same rule.
        assert_eq!(RawRetention::from_json(&json!("forever")), RawRetention::FOREVER);
        assert_eq!(RawRetention::from_json(&json!("FOREVER ")), RawRetention::FOREVER, "trimmed, case-insensitive");
        assert_eq!(RawRetention::from_json(&json!(14)), RawRetention::FOREVER, "a bare number is not a window");
        assert_eq!(RawRetention::from_json(&json!(null)), RawRetention::FOREVER);
        assert_eq!(RawRetention::from_json(&json!({"age_days": "nope", "total_bytes": "nope"})), RawRetention::FOREVER);
        // An axis PRESENT and readable is honoured; an axis absent from a present object is
        // forever, not the shipping default — otherwise "forever" would still delete at 2 GB.
        assert_eq!(
            RawRetention::from_json(&json!({"age_days": 30})),
            RawRetention { age_days: RetentionLimit::Of(30), total_bytes: RetentionLimit::Forever }
        );
        assert_eq!(
            RawRetention::from_json(&json!({"ageDays": 30, "totalBytes": 99})),
            RawRetention::of(30, 99),
            "camelCase is accepted too — a key spelling that misses is a silent retention change"
        );
        // And the one that actually deletes is only reachable by writing it.
        assert_eq!(RawRetention::from_json(&json!({"age_days": 0, "total_bytes": 0})), RawRetention::of(0, 0));
    }

    #[test]
    fn the_window_round_trips_through_json_in_both_shapes() {
        // What lands in `config.json`, read back. `forever` is a token, not a number, so a
        // human editing the file by hand sees a word rather than a sentinel to decode.
        let text = serde_json::to_string(&RawRetention::FOREVER).unwrap();
        assert_eq!(text, r#"{"age_days":"forever","total_bytes":"forever"}"#);
        assert_eq!(serde_json::from_str::<RawRetention>(&text).unwrap(), RawRetention::FOREVER);

        let text = serde_json::to_string(&RawRetention::default()).unwrap();
        assert_eq!(text, r#"{"age_days":14,"total_bytes":2147483648}"#);
        assert_eq!(serde_json::from_str::<RawRetention>(&text).unwrap(), RawRetention::default());
        assert!(!RawRetention::default().is_forever());
        assert!(RawRetention::FOREVER.is_forever());
        assert!(!RawRetention { age_days: RetentionLimit::Forever, total_bytes: RetentionLimit::Of(1) }.is_forever(),
            "a ceiling that can still evict is not forever");
        assert_eq!(RetentionLimit::Of(14).value(), Some(14));
        assert_eq!(RetentionLimit::Forever.value(), None);
    }

    #[test]
    fn deleting_a_thread_deletes_its_machinery() {
        // §2.5 rule 6. Anything else means "delete" does not mean delete.
        let root = tmp();
        let j = MachineryJournal::new(&root);
        j.append(&rec("thr_a", Some("t"), 0, 1_756_425_600_000, 10)).unwrap();
        assert!(root.join("thr_a").exists());
        j.delete_thread("thr_a").unwrap();
        assert!(!root.join("thr_a").exists());
        assert!(j.read_thread("thr_a").is_empty());
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn the_projection_excludes_internal_records() {
        // §1.5: re-prime / rotation machinery is RETAINED for debugging and NEVER rendered.
        let root = tmp();
        let j = MachineryJournal::new(&root);
        let mut internal = rec("thr_a", None, 0, 1_756_425_600_000, 4);
        internal.internal = true;
        internal.tool_call_id = Some("internal_call".into());
        j.append(&internal).unwrap();
        j.append(&rec("thr_a", Some("t1"), 1, 1_756_425_600_000, 4)).unwrap();
        assert_eq!(j.read_thread("thr_a").len(), 2, "both retained on disk");
        let rows = j.project_thread("thr_a");
        assert_eq!(rows.len(), 1, "only the CEO-visible one is projected");
        assert_eq!(rows[0].turn_id.as_deref(), Some("t1"));
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn appending_a_tool_call_lifecycle_projects_to_one_row() {
        let root = tmp();
        let j = MachineryJournal::new(&root);
        let at = 1_756_425_600_000;
        for (i, u) in [
            json!({"sessionUpdate":"tool_call","toolCallId":"tc","status":"pending","title":"Terminal"}),
            json!({"sessionUpdate":"tool_call_update","toolCallId":"tc","title":"wc -l util.rs"}),
            json!({"sessionUpdate":"tool_call_update","toolCallId":"tc","status":"completed","rawOutput":"      18 util.rs"}),
        ]
        .iter()
        .enumerate()
        {
            let mut r = MachineryRecord::from_acp_update(u, "s", i as u64).unwrap().stamp("thr_a", Some("t1"), false);
            r.at = at;
            j.append(&r).unwrap();
        }
        assert_eq!(j.read_thread("thr_a").len(), 3, "append-only: three lines on disk (G6)");
        let rows = j.project_thread("thr_a");
        assert_eq!(rows.len(), 1, "one row after the merge (G2)");
        assert_eq!(rows[0].title, "wc -l util.rs");
        assert_eq!(rows[0].status, Some(ToolStatus::Completed));
        assert_eq!(rows[0].summary.as_deref(), Some("18 util.rs"));
        std::fs::remove_dir_all(&root).ok();
    }
}
