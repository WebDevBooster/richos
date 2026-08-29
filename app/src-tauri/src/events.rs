//! The ADDITIVE live-work event relay (UX brief §13, slice 3 of §24).
//!
//! A separate module rather than another block at the bottom of `main.rs`, for two
//! reasons: `main.rs` should not grow without bound, and slice 4's Tauri query commands
//! are being appended to that same file on a parallel branch — a new module turns a
//! certain conflict into a one-line one.
//!
//! ## What this layer is allowed to do
//!
//! **Relay a name and a payload. Nothing else.** It builds no payload, resolves no scope,
//! makes no visibility decision and knows no event names. All of that lives in
//! `richos_core::live`, where it is unit-tested without a webview; if this file could
//! construct an event, the ECS fence and the visibility gate would both be one careless
//! edit away from being bypassed. `LiveEvent`'s fence is not even constructible from here
//! — `EventFence::for_turn` is crate-private to richos-core and takes a `ThreadBinding`
//! only the ledger can issue.
//!
//! ## Why a THIRD emitter beside `TauriEmitter` and `TauriMachineryEmitter`
//!
//! Three observers means three subscription lists, and a UI's subscription list is then
//! the PROOF of what it can render rather than a promise about what it chooses to:
//!
//!   - `rich://turn-started` / `chunk` / `turn-completed` / `turn-error` — the shipping
//!     calm view. **Completely unchanged by this slice** (`app/STREAMING.md`).
//!   - `rich://machinery` — the technical family, which the calm view does not subscribe
//!     to and must not.
//!   - the six §13 events below — the typed calm family: turn status, message phase,
//!     semantic activity, thread summary. Only `Visibility::Ceo` items are ever handed to
//!     it, and the spine's `forward_live` chokepoint is what enforces that, before this
//!     file ever sees an event.
//!
//! A webview subscribing to nothing new keeps working exactly as it does today.

use richos_core::live::{LiveEvent, LiveObserver};
use tauri::{AppHandle, Emitter};

/// Forwards each additive §13 event to the webview under its own event name.
///
/// Same shape and same posture as `TauriEmitter`: best-effort, infallible from the
/// spine's view. §13's ordering rules say *"missed UI events never block the spine"* and
/// *"the ledger and typed task graph remain authoritative"* — so a dropped or absent
/// webview can never stall or fail a turn, and the `let _ =` is deliberate.
pub struct TauriLiveEmitter {
    pub app: AppHandle,
}

impl LiveObserver for TauriLiveEmitter {
    fn on_live_event(&self, event: &LiveEvent) {
        let _ = self.app.emit(event.event_name(), event.payload());
    }
}
