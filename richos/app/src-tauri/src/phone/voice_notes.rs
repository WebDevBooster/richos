//! **HOW LONG A PHONE VOICE NOTE WAS** — so a native app can draw "0:08" on the bubble from the
//! conversation itself, not only from the copy of the recording it still holds.
//!
//! # Where the number comes from, and the only place it exists
//!
//! The Mac learns the length once: from the WAV it validates at intake, `samples ÷ 16,000 Hz`
//! (`voice.rs` `validate` refuses any other rate or channel count). Nothing downstream keeps it —
//! the transcript enters the intake log as ordinary text and becomes a turn whose projected CEO
//! row is `{turn}:user`, `kind:"text"`. So this desk records `(intake id, thread, duration)` at
//! intake, durably, and joins it to the row later through the one exact link that exists:
//! the ledger's own `turn_for_intake` ([`super::routes::Bridge::turn_for_intake`], an id and
//! nothing else).
//!
//! # What carries it
//!
//! - the voice POST answer (`duration_ms`), exact, at once;
//! - every `hello` and backfill row for that message (`duration_ms`), exact, once the turn exists.
//!
//! **Not the live `message` frame for the CEO row.** That frame is emitted from inside the spine
//! while it holds its own lock, before any intake-to-turn link is readable from here; attaching a
//! duration there would mean matching on text, which can put one message's length on another.
//! The phone that sent the note has the number from its POST answer, and the next `hello` or
//! backfill carries it for everyone. Desktop voice-mode turns (`kind:"voice"`, `from_microphone`)
//! have no recording length anywhere and never carry the field.

use super::{now_millis, PhoneError};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// The most notes remembered; the oldest is forgotten first. At one voice note a minute for
/// sixteen hours a day that is two days — history older than that simply shows no length.
pub const MAX_NOTES: usize = 2000;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
struct Note {
    /// The intake message id the POST answered with (`intake_<n>`).
    intake: String,
    thread: String,
    duration_ms: u64,
    /// The turn that intake became, once known.
    #[serde(default)]
    turn: Option<String>,
    at: u64,
}

pub struct VoiceNoteDesk {
    path: PathBuf,
    notes: Mutex<Option<Vec<Note>>>,
    max: usize,
}

/// Milliseconds of 16 kHz mono audio: `samples × 1000 ÷ 16,000`, floored. 128,000 samples is
/// 8,000 ms; one sample is 0.0625 ms, so the floor loses under a millisecond.
pub fn duration_ms(samples: usize) -> u64 {
    samples as u64 * 1000 / 16_000
}

impl VoiceNoteDesk {
    /// No I/O until first use, like the other desks `DeviceDesk::open` builds.
    pub fn open(dir: &Path) -> Self {
        VoiceNoteDesk { path: dir.join("phone").join("voice-notes.json"), notes: Mutex::new(None), max: MAX_NOTES }
    }

    fn load(&self, slot: &mut Option<Vec<Note>>) {
        if slot.is_none() {
            let notes = std::fs::read(&self.path)
                .ok()
                .and_then(|bytes| serde_json::from_slice::<Vec<Note>>(&bytes).ok())
                .unwrap_or_default();
            *slot = Some(notes);
        }
    }

    fn persist(&self, notes: &[Note]) -> Result<(), PhoneError> {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let io = |e: std::io::Error| PhoneError::Io(e.to_string());
        std::fs::create_dir_all(self.path.parent().unwrap()).map_err(io)?;
        let pending = self.path.with_extension("pending");
        let mut file = std::fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&pending).map_err(io)?;
        file.write_all(&serde_json::to_vec(notes).map_err(|e| PhoneError::Malformed(e.to_string()))?).map_err(io)?;
        file.sync_all().map_err(io)?;
        std::fs::rename(&pending, &self.path).map_err(io)
    }

    /// Remember one accepted voice note. Idempotent on the intake id.
    pub fn record(&self, intake: &str, thread: &str, duration_ms: u64) -> Result<(), PhoneError> {
        let mut slot = self.notes.lock().unwrap();
        self.load(&mut slot);
        let notes = slot.as_mut().unwrap();
        if notes.iter().any(|n| n.intake == intake) {
            return Ok(());
        }
        notes.push(Note { intake: intake.into(), thread: thread.into(), duration_ms, turn: None, at: now_millis() });
        if notes.len() > self.max {
            let excess = notes.len() - self.max;
            notes.drain(..excess);
        }
        self.persist(notes)
    }

    /// Put `duration_ms` on every CEO row that was a phone voice note. `turn_for_intake` is asked
    /// only about notes not yet linked, and a link once found is kept.
    pub fn annotate(&self, rows: &mut [Value], turn_for_intake: &dyn Fn(&str) -> Option<String>) {
        let mut slot = self.notes.lock().unwrap();
        self.load(&mut slot);
        let notes = slot.as_mut().unwrap();
        let mut linked = false;
        for note in notes.iter_mut().filter(|n| n.turn.is_none()) {
            if let Some(turn) = turn_for_intake(&note.intake) {
                note.turn = Some(turn);
                linked = true;
            }
        }
        if linked {
            if let Err(error) = self.persist(notes) {
                eprintln!("[richos] a voice note's length could not be saved; it is still shown: {error}");
            }
        }
        for row in rows.iter_mut().filter(|r| r["role"] == "ceo") {
            let Some(turn) = row["id"].as_str().and_then(|id| id.strip_suffix(":user")) else { continue };
            let thread = row["thread_id"].as_str().unwrap_or("");
            if let Some(note) = notes.iter().find(|n| n.turn.as_deref() == Some(turn) && n.thread == thread) {
                row["duration_ms"] = json!(note.duration_ms);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Scratch(PathBuf);
    impl Scratch {
        fn new() -> Self {
            let p = std::env::temp_dir().join(format!("phone-voice-notes-{}", super::super::hex(&super::super::random_bytes(8).unwrap())));
            std::fs::create_dir_all(&p).unwrap();
            Scratch(p)
        }
    }
    // Said, not asserted: a panic inside Drop while a failing test unwinds would abort the run.
    impl Drop for Scratch {
        fn drop(&mut self) {
            if let Err(e) = std::fs::remove_dir_all(&self.0) {
                eprintln!("test scratch {} was not removed: {e}", self.0.display());
            }
        }
    }

    fn row(id: &str, role: &str) -> Value {
        json!({"id": id, "thread_id": "thr_a", "role": role, "kind": "text", "text": "x"})
    }

    #[test]
    fn the_arithmetic_is_samples_at_sixteen_kilohertz() {
        assert_eq!(duration_ms(128_000), 8_000);
        assert_eq!(duration_ms(16_000 * 30 * 60), 1_800_000, "the 30-minute ceiling");
        assert_eq!(duration_ms(15), 0);
        assert_eq!(duration_ms(16), 1);
    }

    #[test]
    fn a_note_reaches_its_own_row_exactly_and_survives_a_restart() {
        let dir = Scratch::new();
        let desk = VoiceNoteDesk::open(&dir.0);
        desk.record("intake_7", "thr_a", 8_250).unwrap();
        desk.record("intake_7", "thr_a", 9_999).unwrap(); // a retried answer changes nothing
        let mut rows = vec![row("t1:user", "ceo"), row("t2:user", "ceo"), row("t2", "rich")];
        // The turn does not exist yet: nothing is guessed.
        desk.annotate(&mut rows, &|_| None);
        assert!(rows.iter().all(|r| r.get("duration_ms").is_none()));
        desk.annotate(&mut rows, &|intake| (intake == "intake_7").then(|| "t2".to_string()));
        assert_eq!(rows[1]["duration_ms"], 8_250);
        assert!(rows[0].get("duration_ms").is_none() && rows[2].get("duration_ms").is_none());
        drop(desk);
        // After a restart the link is remembered and the ledger is not asked again.
        let desk = VoiceNoteDesk::open(&dir.0);
        let mut again = vec![row("t2:user", "ceo")];
        desk.annotate(&mut again, &|_| panic!("asked the ledger for a link it already had"));
        assert_eq!(again[0]["duration_ms"], 8_250);
    }

    #[test]
    fn a_row_in_another_conversation_or_a_desktop_voice_turn_gets_nothing() {
        let dir = Scratch::new();
        let desk = VoiceNoteDesk::open(&dir.0);
        desk.record("intake_1", "thr_other", 3_000).unwrap();
        let mut rows = vec![row("t1:user", "ceo"), json!({"id":"t5:user","thread_id":"thr_a","role":"ceo","kind":"voice","from_microphone":true})];
        desk.annotate(&mut rows, &|_| Some("t1".into()));
        assert!(rows.iter().all(|r| r.get("duration_ms").is_none()));
    }

    #[test]
    fn the_oldest_notes_are_forgotten_past_the_ceiling() {
        let dir = Scratch::new();
        // The production ceiling is 2000; 20 proves the same rule without 2005 fsyncs.
        let desk = VoiceNoteDesk { max: 20, ..VoiceNoteDesk::open(&dir.0) };
        for n in 0..25 {
            desk.record(&format!("intake_{n}"), "thr_a", n as u64).unwrap();
        }
        let saved: Vec<Note> = serde_json::from_slice(&std::fs::read(dir.0.join("phone/voice-notes.json")).unwrap()).unwrap();
        assert_eq!(saved.len(), 20);
        assert_eq!(saved[0].intake, "intake_5");
    }
}
