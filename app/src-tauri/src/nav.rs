//! NAVIGATION STATE — the shell's own durable *view* preferences (UX §3.1, §25).
//!
//! Codex-UX slice 4 needs four things persisted that are not conversation evidence:
//! pin, rename, archive and the left-navigation width. This module is where they live,
//! and the choice of where deserves a sentence, because it is load-bearing rather than
//! incidental.
//!
//! **These are NOT ledger events, deliberately.** §25 Navigation says *"Search, pin,
//! rename and archive work WITHOUT changing context authority."* The conversation ledger
//! is evidence — it records what the CEO said, what Rich said, and which entity each
//! thread is bound to. A thread's title as written into `Event::ThreadCreated` is part of
//! that record. Overwriting it because the CEO wanted a tidier label in a list would edit
//! evidence to serve a rail, and the ledger has no rename/pin/archive event to append
//! instead (adding one is a `richos-core` change and belongs to whoever owns that crate).
//!
//! So a rename here is a DISPLAY OVERRIDE: the durable ledger title is untouched and
//! still returned by `list_threads`; the rail prefers the override when one exists. Pin
//! and archive are pure view state and never touch scope — an archived thread is still
//! bound to exactly the entity it was always bound to, still readable, just not in the
//! normal list (§3.2: *"Removed from normal list … recoverable through archive view"*).
//!
//! Durability posture matches the ledger and config: one JSON file in the app data dir,
//! written whole, `fsync`ed, and replaced by atomic rename so a crash mid-write leaves
//! either the old file or the new one and never a truncated one. A corrupt or missing
//! file degrades to defaults rather than failing the launch — losing a sidebar width is
//! not worth refusing to start.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

/// Left-navigation width bounds, verbatim from UX §2.1's desktop-shell table
/// (default 300px, minimum 224px, maximum 420px). Clamped in RUST, not only in CSS, so a
/// value that would make the rail unusable can never reach the durable file — the UI is
/// free to be wrong; the store is not.
pub const SIDEBAR_WIDTH_DEFAULT: f64 = 300.0;
pub const SIDEBAR_WIDTH_MIN: f64 = 224.0;
pub const SIDEBAR_WIDTH_MAX: f64 = 420.0;

/// A rename override is bounded for the same reason an entity id is: it is CEO-supplied
/// text that ends up in a durable file and in the accessible name of a control.
pub const TITLE_MAX_LEN: usize = 200;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct NavState {
    /// Persisted left-navigation width in CSS pixels (§25: *"Left-navigation width can be
    /// changed directly and survives relaunch"*).
    pub sidebar_width: f64,
    /// Whether the rail is collapsed (§20: collapsible between 820px and 1179px).
    pub sidebar_collapsed: bool,
    /// Entity ids whose disclosure is closed. Absent = open, so a newly registered entity
    /// appears expanded rather than silently hidden.
    pub collapsed_entities: Vec<String>,
    /// Thread ids pinned to the top-level `Pinned` group (§3.1).
    pub pinned_threads: Vec<String>,
    /// Thread ids removed from the normal list (§3.2) — recoverable, never deleted.
    pub archived_threads: Vec<String>,
    /// thread_id -> display title override. See the module doc: the ledger title is
    /// evidence and is never rewritten.
    pub renamed_threads: BTreeMap<String, String>,
}

impl Default for NavState {
    fn default() -> Self {
        NavState {
            sidebar_width: SIDEBAR_WIDTH_DEFAULT,
            sidebar_collapsed: false,
            collapsed_entities: Vec::new(),
            pinned_threads: Vec::new(),
            archived_threads: Vec::new(),
            renamed_threads: BTreeMap::new(),
        }
    }
}

pub struct NavStore {
    path: PathBuf,
    state: NavState,
}

impl NavStore {
    /// Load, or start from defaults. NEVER fails on a corrupt or unreadable file — a
    /// mangled preferences file must not stop the CEO's app from launching.
    pub fn open(path: impl AsRef<Path>) -> Self {
        let path = path.as_ref().to_path_buf();
        let state = std::fs::read_to_string(&path)
            .ok()
            .and_then(|raw| serde_json::from_str::<NavState>(&raw).ok())
            .map(|mut s| {
                s.sidebar_width = clamp_width(s.sidebar_width);
                s
            })
            .unwrap_or_default();
        NavStore { path, state }
    }

    pub fn state(&self) -> &NavState {
        &self.state
    }

    /// Write whole, fsync, then atomically rename over the live file.
    fn persist(&self) -> std::io::Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        let encoded = serde_json::to_vec_pretty(&self.state)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
        {
            let mut f = std::fs::File::create(&tmp)?;
            f.write_all(&encoded)?;
            f.flush()?;
            f.sync_data()?;
        }
        std::fs::rename(&tmp, &self.path)
    }

    /// Returns the width actually stored, which is the CLAMPED one — the caller renders
    /// what the store accepted rather than what it asked for, so the UI and the durable
    /// file can never disagree about the rail's width.
    pub fn set_sidebar_width(&mut self, width: f64) -> std::io::Result<f64> {
        self.state.sidebar_width = clamp_width(width);
        self.persist()?;
        Ok(self.state.sidebar_width)
    }

    pub fn set_sidebar_collapsed(&mut self, collapsed: bool) -> std::io::Result<()> {
        self.state.sidebar_collapsed = collapsed;
        self.persist()
    }

    pub fn set_entity_collapsed(&mut self, entity_id: &str, collapsed: bool) -> std::io::Result<()> {
        set_membership(&mut self.state.collapsed_entities, entity_id, collapsed);
        self.persist()
    }

    pub fn set_thread_pinned(&mut self, thread_id: &str, pinned: bool) -> std::io::Result<()> {
        set_membership(&mut self.state.pinned_threads, thread_id, pinned);
        self.persist()
    }

    pub fn set_thread_archived(&mut self, thread_id: &str, archived: bool) -> std::io::Result<()> {
        set_membership(&mut self.state.archived_threads, thread_id, archived);
        self.persist()
    }

    /// An empty/blank title CLEARS the override rather than storing a blank one, so the
    /// rail falls back to the ledger's real title instead of rendering a nameless row.
    pub fn rename_thread(&mut self, thread_id: &str, title: &str) -> std::io::Result<()> {
        let trimmed: String = title.trim().chars().take(TITLE_MAX_LEN).collect();
        if trimmed.is_empty() {
            self.state.renamed_threads.remove(thread_id);
        } else {
            self.state.renamed_threads.insert(thread_id.to_string(), trimmed);
        }
        self.persist()
    }
}

fn clamp_width(w: f64) -> f64 {
    if !w.is_finite() {
        return SIDEBAR_WIDTH_DEFAULT;
    }
    w.clamp(SIDEBAR_WIDTH_MIN, SIDEBAR_WIDTH_MAX)
}

/// Idempotent set membership on a `Vec<String>` used as a small ordered set. Idempotent
/// because a double-click on `Pin` must not produce two entries that then need two
/// unpins to undo.
fn set_membership(set: &mut Vec<String>, id: &str, member: bool) {
    let present = set.iter().any(|x| x == id);
    match (member, present) {
        (true, false) => set.push(id.to_string()),
        (false, true) => set.retain(|x| x != id),
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_path(name: &str) -> PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!("richos-nav-test-{}-{}.json", name, std::process::id()));
        let _ = std::fs::remove_file(&p);
        p
    }

    #[test]
    fn width_is_clamped_to_the_ux_shell_bounds_in_rust_not_only_in_css() {
        let path = tmp_path("width");
        let mut store = NavStore::open(&path);
        assert_eq!(store.state().sidebar_width, SIDEBAR_WIDTH_DEFAULT);
        assert_eq!(store.set_sidebar_width(10.0).unwrap(), SIDEBAR_WIDTH_MIN);
        assert_eq!(store.set_sidebar_width(9000.0).unwrap(), SIDEBAR_WIDTH_MAX);
        assert_eq!(store.set_sidebar_width(f64::NAN).unwrap(), SIDEBAR_WIDTH_DEFAULT);
        assert_eq!(store.set_sidebar_width(312.0).unwrap(), 312.0);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn width_survives_relaunch() {
        let path = tmp_path("relaunch");
        {
            let mut store = NavStore::open(&path);
            store.set_sidebar_width(388.0).unwrap();
        }
        let reopened = NavStore::open(&path);
        assert_eq!(reopened.state().sidebar_width, 388.0, "§25: width must survive relaunch");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn pin_and_archive_are_idempotent_sets() {
        let path = tmp_path("sets");
        let mut store = NavStore::open(&path);
        store.set_thread_pinned("thr_a", true).unwrap();
        store.set_thread_pinned("thr_a", true).unwrap();
        assert_eq!(store.state().pinned_threads, vec!["thr_a".to_string()]);
        store.set_thread_pinned("thr_a", false).unwrap();
        assert!(store.state().pinned_threads.is_empty());
        store.set_thread_archived("thr_b", true).unwrap();
        assert_eq!(store.state().archived_threads, vec!["thr_b".to_string()]);
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn blank_rename_clears_the_override_rather_than_storing_a_nameless_row() {
        let path = tmp_path("rename");
        let mut store = NavStore::open(&path);
        store.rename_thread("thr_a", "  Acme counter  ").unwrap();
        assert_eq!(store.state().renamed_threads.get("thr_a").unwrap(), "Acme counter");
        store.rename_thread("thr_a", "   ").unwrap();
        assert!(store.state().renamed_threads.get("thr_a").is_none());
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_corrupt_file_degrades_to_defaults_instead_of_refusing_to_launch() {
        let path = tmp_path("corrupt");
        std::fs::write(&path, b"{ this is not json").unwrap();
        let store = NavStore::open(&path);
        assert_eq!(store.state(), &NavState::default());
        let _ = std::fs::remove_file(&path);
    }
}
