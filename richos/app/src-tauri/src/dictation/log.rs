//! `dictation.log`: model, length, latency and the event-tap numbers, never the words (plan
//! section 6). Every line also goes to stderr behind `[richos-dictation]`, which is the app's log
//! when the tool is the app's child.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

pub const FILE_NAME: &str = "dictation.log";

static PATH: OnceLock<PathBuf> = OnceLock::new();

/// Log into `<data dir>/dictation.log` from now on.
pub fn init(data_dir: &Path) {
    PATH.set(data_dir.join(FILE_NAME)).ok();
}

pub fn line(message: &str) {
    eprintln!("[richos-dictation] {message}");
    if let Some(path) = PATH.get() {
        let stamp = crate::startup_alert::utc_stamp(
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0),
        );
        append(path, &stamp, message);
    }
}

/// One stamped line into `path`, whatever `init` was given: for a note written before the data
/// folder is known (tool.rs `early_failure_note`).
pub fn line_to(path: &Path, message: &str) {
    eprintln!("[richos-dictation] {message}");
    let stamp = crate::startup_alert::utc_stamp(
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0),
    );
    append(path, &stamp, message);
}

fn append(path: &Path, stamp: &str, message: &str) {
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        writeln!(f, "{stamp} {message}").ok();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// INVARIANT: one line per call, stamped, appended: an earlier line is never overwritten.
    #[test]
    fn lines_are_appended_with_their_stamp() {
        let path = std::env::temp_dir().join(format!("richos-dictation-log-{}", std::process::id()));
        std::fs::remove_file(&path).ok();
        append(&path, "2026-10-08T10:00:00.000Z", "dictation: model small.en, 3.10 s of audio, written in 812 ms, pasted");
        append(&path, "2026-10-08T10:00:05.000Z", "key tap: longest callback 41 us in the last hour; 0 disable(s) so far");
        let text = std::fs::read_to_string(&path).unwrap();
        assert_eq!(text.lines().count(), 2);
        assert!(text.starts_with("2026-10-08T10:00:00.000Z dictation: model small.en"));
        std::fs::remove_file(&path).unwrap();
    }

    /// INVARIANT: a line to a named file is stamped and appended there, whatever `init` holds:
    /// the start-failure note a launchd-started tool leaves before it knows its data folder.
    #[test]
    fn a_line_to_a_named_file_is_stamped_and_appended() {
        let path = std::env::temp_dir().join(format!("richos-dictation-note-{}", std::process::id()));
        std::fs::remove_file(&path).ok();
        line_to(&path, "no --data-dir, and the installed data folder cannot be used: HOME is /x");
        line_to(&path, "second");
        let text = std::fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), 2);
        assert!(lines[0].ends_with("Z no --data-dir, and the installed data folder cannot be used: HOME is /x"), "{text}");
        assert!(lines[0].starts_with("20"), "stamped: {text}");
        std::fs::remove_file(&path).unwrap();
    }
}
