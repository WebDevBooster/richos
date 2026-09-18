//! **WHERE THE CEO'S OWN VOICE LIVES, AND WHY IT IS NOT IN THIS REPOSITORY.**
//!
//! One fixture in the echo-path family is a microphone recording with the CEO speaking into it:
//!
//! ```text
//!   ceo-rig-2026-09-18-nearend2-mic.wav   793132 bytes
//!   sha256 786adf8073d0eee99b5a1d639abc5f459e2f6c1284188ab33d75ba8c1f93cfe3
//! ```
//!
//! `richos` is a public repository and nothing carrying his voice goes into one. So that single
//! file lives in the private `richos-hq` repository at
//! `fixtures/echo-path/ceo-rig-2026-09-18-nearend2-mic.wav`, and this module is how the tests and
//! the scoring harness find it. **Every other file of that pair is committed here**, including
//! `-nearend2-reference.wav` (the signal that went to the DAC — synthetic `say` output, measured
//! to carry no trace of him) and `-nearend2-nearend.json` (the intervals and the levels, and not
//! one word he said).
//!
//! # The two places it looks, in order
//!
//! 1. **`$RICHOS_PRIVATE_FIXTURES`** — a DIRECTORY. Set it and the file is looked for inside it.
//!    This is the form to use from a git worktree, where the sibling guess below cannot work.
//! 2. **`<repo-root>/../richos-hq/fixtures/echo-path`** — the side-by-side checkout layout
//!    (`~/ab/richos` beside `~/ab/richos-hq`), which needs no configuration on the machine the
//!    recordings were made on. The repository root is found by walking up from
//!    `CARGO_MANIFEST_DIR` to the first directory holding a `.git` entry, so it is correct for a
//!    worktree too (where `.git` is a file) — but a worktree's PARENT is not `~/ab`, which is
//!    exactly why (1) exists.
//!
//! Neither one found means the file is **unavailable**, which is a first-class outcome here and
//! never an error: see the `private_fixtures` cfg in `build.rs` for what the tests do about it.
//!
//! # This file is compiled TWICE, on purpose
//!
//! `build.rs` pulls it in with `include!` so that the compile-time cfg and the run-time file open
//! can never disagree about where the fixture is. One definition, two consumers — the same reason
//! `tests/barge_in_on_the_ceos_rig.rs` and `tests/self_voice_replay.rs` derive the volume knob by
//! sharing a method instead of sharing a constant. So: **no `crate::` or `super::` paths in here,
//! and no dependency on anything outside `std`.**

use std::path::{Path, PathBuf};

/// The directory to look in, when the caller says where it is.
pub const ENV_DIR: &str = "RICHOS_PRIVATE_FIXTURES";

/// The private repository the recording lives in.
pub const PRIVATE_REPO: &str = "richos-hq";

/// Where inside that repository, which is also what `$RICHOS_PRIVATE_FIXTURES` should point at.
pub const IN_REPO_DIR: &str = "fixtures/echo-path";

/// The side-by-side guess, relative to the PARENT of this repository's root.
pub const SIBLING_DIR: &str = "richos-hq/fixtures/echo-path";

/// The one file this whole module exists for.
pub const CEO_MIC_TRACK: &str = "ceo-rig-2026-09-18-nearend2-mic.wav";

/// The file is not on this machine, and every place that was looked in.
#[derive(Debug, Clone)]
pub struct Unavailable {
    pub file_name: String,
    pub tried: Vec<PathBuf>,
}

impl Unavailable {
    /// **The printed reason — it names the file, every path tried, and the fix.**
    ///
    /// Deliberately long. A skipped measurement that does not say what it was measuring is how a
    /// gap becomes permanent, and this text is the only thing a reader of a skipped run gets.
    pub fn reason(&self) -> String {
        let mut s = format!(
            "PRIVATE FIXTURE NOT ON THIS MACHINE: {}\n  \
             It is a microphone recording with the CEO's own voice in it, so it is not committed \
             to this public repository. It lives in the private `{PRIVATE_REPO}` repository at \
             `{IN_REPO_DIR}/{}`.\n  Looked in:\n",
            self.file_name, self.file_name,
        );
        for p in &self.tried {
            s.push_str(&format!("    {}\n", p.display()));
        }
        s.push_str(&format!(
            "  To run this, point {ENV_DIR} at that directory:\n    \
             {ENV_DIR}=/path/to/{PRIVATE_REPO}/{IN_REPO_DIR} cargo test -p richos-voice --release\n  \
             Nothing is fabricated in its absence and no substitute recording is used."
        ));
        s
    }
}

/// Walk up from `start` to the first directory holding a `.git` entry (a directory in a normal
/// clone, a FILE in a git worktree — `Path::exists` is true for both, which is the point).
pub fn repo_root(start: &Path) -> Option<PathBuf> {
    let mut d = start;
    loop {
        if d.join(".git").exists() {
            return Some(d.to_path_buf());
        }
        d = d.parent()?;
    }
}

/// Every directory that might hold the private fixtures, in the order they are consulted.
///
/// `$RICHOS_PRIVATE_FIXTURES` first when it is set, because a machine that has said where the
/// file is should never be second-guessed by a guess.
pub fn candidate_dirs(manifest_dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    if let Some(d) = std::env::var_os(ENV_DIR) {
        if !d.is_empty() {
            out.push(PathBuf::from(d));
        }
    }
    if let Some(root) = repo_root(manifest_dir) {
        if let Some(parent) = root.parent() {
            out.push(parent.join(SIBLING_DIR));
        }
    }
    out
}

/// **Find `file_name`, or say precisely where it is not.** Never fabricates, never substitutes,
/// never returns a path that does not exist.
pub fn locate(manifest_dir: &Path, file_name: &str) -> Result<PathBuf, Unavailable> {
    let mut tried = Vec::new();
    for dir in candidate_dirs(manifest_dir) {
        let p = dir.join(file_name);
        if p.is_file() {
            return Ok(p);
        }
        tried.push(p);
    }
    Err(Unavailable { file_name: file_name.to_string(), tried })
}

/// `locate` for the one file above, from this crate's own manifest directory.
pub fn ceo_mic_track() -> Result<PathBuf, Unavailable> {
    locate(Path::new(env!("CARGO_MANIFEST_DIR")), CEO_MIC_TRACK)
}

/// **The positive guard, for the same reason `live_audio::require_opt_in` exists.**
///
/// `#[ignore]` suppresses the RUN, not the BODY, so `cargo test -- --include-ignored` on a machine
/// without the private repository would enter a test that cannot be performed. This is what it
/// enters instead: a panic carrying the full reason — which file, where it was looked for, and
/// how to provide it. A red line that explains itself, never a green one that does not, and never
/// a substitute recording standing in for him.
pub fn require_ceo_mic_track() -> PathBuf {
    match ceo_mic_track() {
        Ok(p) => p,
        Err(u) => panic!(
            "this test measures whether the CEO is heard and the recording of him is not on \
             this machine.\n{}",
            u.reason()
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The reason text is the entire output of a skipped run, so it has to carry the three things
    /// a reader needs: what is missing, that it is missing because it is his voice, and how to
    /// get it. Asserted rather than trusted to survive an edit.
    #[test]
    fn the_printed_reason_names_the_file_the_private_repo_and_the_fix() {
        let u = Unavailable {
            file_name: CEO_MIC_TRACK.to_string(),
            tried: vec![PathBuf::from("/nowhere/ceo-rig-2026-09-18-nearend2-mic.wav")],
        };
        let r = u.reason();
        assert!(r.contains(CEO_MIC_TRACK), "{r}");
        assert!(r.contains("richos-hq"), "{r}");
        assert!(r.contains(ENV_DIR), "{r}");
        assert!(r.contains("/nowhere/ceo-rig-2026-09-18-nearend2-mic.wav"), "{r}");
        assert!(r.contains("CEO's own voice"), "{r}");

        // **A REAL BUG THIS CAUGHT ON THE FIRST BUILD, pinned so it cannot come back.** The text
        // used to interpolate `SIBLING_DIR` after the words "the private `richos-hq` repository
        // at", and printed `richos-hq/richos-hq/fixtures/echo-path` — an instruction that does not
        // work, inside the one message a reader of a skipped run gets. The paths a person is told
        // to type are `IN_REPO_DIR`; `SIBLING_DIR` is only ever joined to a filesystem parent.
        assert!(
            !r.contains("richos-hq/richos-hq"),
            "the reason text doubles the repository name, so the path it tells you to use is \
             wrong:\n{r}"
        );
    }

    /// `SIBLING_DIR` is the other two constants joined. Asserted because it is spelled out
    /// separately (a `const` cannot be a runtime `format!`) and a silent divergence would send the
    /// sibling lookup to a directory the printed instructions never mention.
    #[test]
    fn the_sibling_guess_is_the_repo_name_joined_to_the_in_repo_directory() {
        assert_eq!(SIBLING_DIR, format!("{PRIVATE_REPO}/{IN_REPO_DIR}"));
    }

    /// A path that does not exist is never returned as a hit, and the error lists what was tried.
    #[test]
    fn a_missing_file_is_unavailable_and_not_a_path() {
        let dir = std::env::temp_dir().join(format!("richos-privfix-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let err = locate(&dir, "definitely-not-here.wav").unwrap_err();
        assert_eq!(err.file_name, "definitely-not-here.wav");
        for p in &err.tried {
            assert!(!p.exists(), "listed a path that exists as 'tried': {}", p.display());
        }
        let _ = std::fs::remove_dir(&dir);
    }

    /// `repo_root` finds the worktree root this crate is actually in, and that root really does
    /// hold a `.git` entry. Guards the sibling-directory guess against silently resolving to `/`.
    #[test]
    fn repo_root_is_a_real_checkout_root() {
        let here = Path::new(env!("CARGO_MANIFEST_DIR"));
        let root = repo_root(here).expect("this crate is inside a git checkout");
        assert!(root.join(".git").exists(), "{} has no .git", root.display());
        assert!(here.starts_with(&root));
    }
}
