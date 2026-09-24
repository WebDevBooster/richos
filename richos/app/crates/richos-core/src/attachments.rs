//! **WHERE A CONVERSATION'S ATTACHED FILES LIVE**, named once for everyone who reaches them.
//!
//! Two parties need the same folder and must never disagree about it:
//!
//! * the attachment desk in the shell (`src-tauri/src/phone/attachments.rs`), which WRITES a
//!   file there when the CEO hands one over, from the phone or from the Mac composer; and
//! * the session that answers him (`engine_profile.rs`), which must be able to READ it, or
//!   "here is the contract" reaches a Rich who can see the path and not the contract.
//!
//! The second was missing until 2026-09-24. Sessions run with
//! `blockReadsOutsideWorkingDirectories`, and `<app data>/attachments/` was in none of the
//! directories they were given, so every attached file, phone or Mac, was out of reach. Found
//! by the Mac composer's VM walk (CEO §86; richos-hq `docs/verification/2026-09-24-mac-drop/`).
//! The grant is ONE conversation's folder, never the root: an attachment is the CEO's, for the
//! conversation he handed it to, and a conversation under another company must not be able to
//! read it.

use sha2::Digest;
use std::path::{Path, PathBuf};

/// A directory name for an identifier that did not come from this Mac. Kept as-is when it is
/// plainly safe (`thr_…`, a UUID); otherwise replaced by `x.<hash>`, which can never collide
/// with a kept one because kept ones contain no `.`.
pub fn segment(id: &str) -> String {
    if !id.is_empty() && id.len() <= 64 && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-') {
        id.to_string()
    } else {
        let digest = format!("{:x}", sha2::Sha256::digest(id.as_bytes()));
        format!("x.{}", &digest[..32])
    }
}

/// `<app data>/attachments/<conversation>`: every file attached in one conversation, in one
/// folder per message beneath it.
pub fn conversation_folder(data: &Path, thread: &str) -> PathBuf {
    data.join("attachments").join(segment(thread))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_thread_id_names_its_own_folder_and_nothing_else_escapes_it() {
        assert_eq!(segment("thr_6ac252bf8292433c918493055f4167d0"), "thr_6ac252bf8292433c918493055f4167d0");
        assert_eq!(
            conversation_folder(Path::new("/data"), "thr_1"),
            PathBuf::from("/data/attachments/thr_1")
        );
        for hostile in ["..", "../x", "a/b", "", ".", "x.y", &"a".repeat(65)] {
            let s = segment(hostile);
            assert!(s.starts_with("x.") && s.len() == 34 && !s.contains('/'), "{hostile:?} -> {s}");
        }
        // The published SHA-256 of "a/b", so the shell's copy of this rule and this one are
        // pinned to the same bytes rather than to each other.
        assert_eq!(segment("a/b"), "x.c14cddc033f64b9dea80ea675cf280a0");
        assert_ne!(segment("a/b"), segment("a/c"));
    }
}
