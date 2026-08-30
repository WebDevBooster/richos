//! The body of `get_machinery` — techy mode's read path (techy-mode design §3.4).
//!
//! In its own file for the same reason `timeline_view.rs` is: an example can include THIS
//! source by path and print the exact JSON the webview receives, so a payload proof cannot
//! drift from the command by re-implementing it.
//!
//! ## Why this is a SECOND command and not a mode argument on `get_timeline`
//! `timeline_view.rs` carries the CEO gate as a property nobody can route around: it calls
//! `view(ViewMode::Ceo)` and `Timeline` does not implement `Serialize`, so that function
//! never holds a raw command, a file path or an internal item. Adding a `mode` parameter
//! to it would trade that structural fact for a branch — and the calm path would then be
//! one wrong argument away from serving technical bytes. So the calm command is untouched,
//! byte for byte, and technical mode arrives through its own door.
//!
//! `ViewMode::Technical` still cannot reach an `Internal` item: `Visibility::renders_in`
//! is false for `Internal` in EVERY mode, and there is deliberately no `ViewMode::Internal`
//! to ask for (timeline.rs). Re-prime traffic, rotation machinery and model reasoning have
//! no render path here either.
//!
//! ## What it does NOT carry, and why
//! No raw payloads. §2.4 caps one payload at 32 KB and a working thread holds hundreds of
//! records, so shipping every raw blob on every thread open would put megabytes through
//! the IPC boundary to render a column of one-line rows. The raw pane is a second command
//! (`get_machinery_raw`), fetched when the CEO actually expands a row.

use richos_core::journal::ThreadMachinery;
use richos_core::spine::Spine;
use richos_core::timeline::ViewMode;
use serde_json::json;

/// The CEO-facing sentence for a thread that ran before the routing commit.
///
/// **"No machinery was recorded for this conversation" and "this conversation had no
/// machinery" are different sentences, and only the first one is true.** Retroactivity
/// began at the routing commit (richos `48561e4`); nothing earlier is recoverable, ever
/// (§5). This says what was recorded, not what happened.
pub const NOTHING_RECORDED: &str =
    "No machinery was recorded for this conversation. Retention started on 2026-08-28, and \
     anything Rich did before that was never written down — so this is a gap in the record, \
     not a quiet conversation.";

/// The CEO-facing sentence when no machinery has ever been retained on this install.
pub const NOT_RETAINED: &str =
    "Nothing has been recorded on this machine yet. The technical view reads a store that \
     hasn't been written to — it fills up as Rich works.";

/// The CEO-facing sentence when the store is there and could not be read. **Never the
/// empty-state sentence:** "I could not read it" and "there is nothing in it" are
/// different statements, and serving the second over the first is how a renderer lies.
/// The operator-facing reason travels alongside, in its own field, and names who owns it.
pub const UNREADABLE: &str =
    "I can't read the technical record for this conversation. It's on this machine and I \
     haven't lost it — something is refusing to open it, and that part isn't yours to fix.";

/// One thread's machinery, as the technical view of its timeline, plus WHY there is
/// nothing when there is nothing.
///
/// The rows are the same items a reload projects, at the same ids, in the same
/// `(turn, slot, sequence)` order — §3.4's *"inline, in `seq` order, interleaved between
/// the message bubbles of the same turn"* is therefore the projection's ordering, not a
/// second ordering invented in the renderer.
///
/// Fails closed on an unbound thread, exactly like `get_messages` and `get_timeline`.
pub fn machinery_payload(spine: &Spine, thread_id: &str) -> Result<serde_json::Value, String> {
    // The state FIRST, and from the checked read — `Spine::timeline` uses the unchecked
    // one, which cannot tell an unreadable directory from an empty thread. If the store
    // refuses, say so and do not hand back a prose-only timeline that reads as "he did
    // nothing".
    let state = match spine.machinery_journal() {
        Some(journal) => journal.project_thread_checked(thread_id),
        // The spine runs headless with no journal attached; so does a shell that failed to
        // create the directory. A fact about the install, not about the thread.
        None => ThreadMachinery::NotRetained,
    };

    let (sentence, reason) = match &state {
        ThreadMachinery::Recorded(_) => (None, None),
        ThreadMachinery::NothingRecorded => (Some(NOTHING_RECORDED), None),
        ThreadMachinery::NotRetained => (Some(NOT_RETAINED), None),
        ThreadMachinery::Unreadable(why) => (Some(UNREADABLE), Some(why.clone())),
    };

    // The timeline is projected even in the empty states: the CEO's conversation is still
    // there and still has to render. What changes is the sentence under it.
    let timeline = spine.timeline(thread_id).map_err(|e| e.to_string())?;
    let view = timeline.view(ViewMode::Technical);

    Ok(json!({
        "threadId": thread_id,
        "state": state.as_str(),
        "rowCount": state.records().len(),
        "sentence": sentence,
        "reason": reason,
        "timeline": view.payload(),
    }))
}
