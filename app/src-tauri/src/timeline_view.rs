//! The body of the `get_timeline` command, in its own module for ONE reason.
//!
//! `examples/timeline_payload.rs` includes THIS FILE by path and calls this function, so
//! the JSON that example prints is byte-for-byte the JSON the webview receives. A payload
//! proof that re-implemented these two lines would prove nothing about the command: the
//! whole failure it exists to catch is a shape mismatch (`activeMs` vs `active_ms`,
//! camelCase vs snake_case, a flattened base vs a nested one) that a parallel
//! implementation would reproduce faithfully in both places and never notice.
//!
//! `src-tauri` is a binary crate, so an example cannot `use` it — `#[path]` inclusion is
//! how one source file ends up compiled into both.

use richos_core::spine::Spine;
use richos_core::timeline::ViewMode;

/// One thread's typed timeline (UX §12), gated to the CEO view (§5.3).
///
/// **THE GATE IS NOT RE-IMPLEMENTED HERE, AND CANNOT BE ROUTED AROUND.** `Timeline`
/// deliberately does not implement `Serialize` — timeline.rs carries a compile-fail
/// doctest asserting it — so there is no ungated path from here to a webview.
/// `view(ViewMode::Ceo)` REMOVES technical items and the technical half of the items it
/// keeps rather than masking them, so this function never holds a raw command, a file path
/// or an internal item and could not leak one if it tried.
///
/// Fails closed on an unbound thread, exactly like `get_messages`: "I will not serve this"
/// and "there is nothing here" are different statements.
pub fn timeline_payload(spine: &Spine, thread_id: &str) -> Result<serde_json::Value, String> {
    let timeline = spine.timeline(thread_id).map_err(|e| e.to_string())?;
    Ok(timeline.view(ViewMode::Ceo).payload())
}
