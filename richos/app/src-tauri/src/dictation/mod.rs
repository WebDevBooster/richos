//! **Dictation in any app: the tool's macOS edges** (`richos-hq/docs/plans/2026-10-08-dictation-anywhere.md`,
//! revision 2, section 1). Each file is thin and named for one platform API; every decision is in
//! `richos_voice::dictation`, where it is unit-tested.
//!
//! - `tool.rs`: the `--richos-dictation` entry and its own Tauri builder.
//! - `keytap.rs`: the active event tap.
//! - `insert.rs`: Accessibility, the pasteboard and Command-V.
//! - `ipc.rs`: the lock, the socket and the protocol, both ends.
//! - `store.rs`: `dictation.json`.
//! - `scratch.rs`: one dictation's private folder.
//! - `log.rs`: `dictation.log`, never the words.
//!
//! Slice 1 builds the tool and the engine with no new screens: the bar, the flight window and
//! the menu bar item are slice 3, the LaunchAgent is slice 5.

pub mod insert;
pub mod ipc;
pub mod keytap;
pub mod log;
pub mod scratch;
pub mod store;
pub mod tool;
