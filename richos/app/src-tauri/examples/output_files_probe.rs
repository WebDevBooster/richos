//! **THE OUTPUT FILE COMMANDS, DRIVEN WITHOUT A PANEL** — the real-app check of the Output side
//! panel's slice S3 (richos-hq `docs/prds/2026-10-05-output-side-panel.md` §12.3).
//!
//! The commands `output_open` and `output_reveal` have no control on the page until slice S4
//! builds the panel, so nothing in the running window can press them yet. This compiles
//! `src/output_files.rs` BY PATH, exactly as `examples/window_placement.rs` compiles
//! `src/window_geometry.rs`, and calls the very functions the `#[tauri::command]` wrappers call:
//! the same id resolution, the same §5.2 checks, the same Launch Services list and the same
//! `/usr/bin/open` arguments. Only the active thread is given on the command line instead of
//! read from the window.
//!
//! ```text
//! output_files_probe record <data-dir> <thread-id> <file>   one witnessed write, through the
//!                                                           S1 store; prints the entry
//! output_files_probe file   <data-dir> <thread-id> <output-id>
//! output_files_probe open   <data-dir> <thread-id> <output-id> [app-index]
//! output_files_probe reveal <data-dir> <thread-id> <output-id>
//! ```
//!
//! Each prints one JSON line, `{"ok": …}` or `{"error": "<the sentence>"}`, and exits 0 or 1.
//! `testvm/output-walk.py`'s `open-reveal` step runs it in the test VM's guest; never on the
//! host, where `open` would put a window on the CEO's screen. Its own test
//! (`scripts/output-files-probe.test.sh`) records and describes a file and opens nothing.
#![allow(dead_code)]

#[path = "../src/output_files.rs"]
mod output_files;

use richos_core::output::{Actor, OutputStore, WriteRow, WriteSource};
use serde_json::{json, Value};
use std::path::Path;

const USAGE: &str =
    "usage: output_files_probe record|file|open|reveal <data-dir> <thread-id> <file-or-output-id> [app-index]";

/// One verb: the exit code and the line to print.
fn run(args: &[String]) -> (i32, Value) {
    if args.len() < 5 {
        return (2, json!({ "error": USAGE }));
    }
    let (verb, data, thread, subject) = (args[1].as_str(), Path::new(&args[2]), args[3].as_str(), args[4].as_str());
    let store = OutputStore::for_data_dir(data);
    let files = output_files::OutputFiles::for_thread(store.clone(), thread, &data.join("probe-cache"));
    let answer: Result<Value, String> = match verb {
        "record" => {
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis() as u64)
                .unwrap_or(0);
            let row = WriteRow::witnessed(format!("probe:{subject}"), thread, None, subject, Actor::Rich, WriteSource::Tool, now);
            store
                .append(thread, &[row])
                .map_err(|e| e.to_string())
                .and_then(|_| files.list(thread))
                .and_then(|list| {
                    list.files
                        .into_iter()
                        .find(|e| e.path == subject)
                        .ok_or_else(|| "the write was appended and is not listed".to_string())
                })
                .map(|entry| serde_json::to_value(entry).unwrap_or_default())
        }
        "file" => files.file(subject).map(|d| serde_json::to_value(d).unwrap_or_default()),
        "open" => {
            let index = args.get(5).and_then(|i| i.parse::<usize>().ok());
            // *Open with…* is compared against the list last shown for the id, as the panel
            // would have shown it first.
            let shown = if index.is_some() { files.file(subject).map(|_| ()) } else { Ok(()) };
            shown.and_then(|_| files.open(subject, index)).map(Value::from)
        }
        "reveal" => files.reveal(subject).map(Value::from),
        _ => return (2, json!({ "error": USAGE })),
    };
    match answer {
        Ok(value) => (0, json!({ "ok": value })),
        Err(sentence) => (1, json!({ "error": sentence })),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let (code, line) = run(&args);
    println!("{line}");
    std::process::exit(code);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(words: &[&str]) -> Vec<String> {
        std::iter::once("output_files_probe").chain(words.iter().copied()).map(str::to_string).collect()
    }

    /// The probe records a file through the S1 store, finds it by its id, and refuses an id
    /// the record does not hold with the command's own sentence. Nothing is opened: the one
    /// `open` here is refused before `/usr/bin/open` is reached.
    #[test]
    fn the_probe_records_describes_and_refuses_with_the_commands_sentences() {
        let root = std::env::temp_dir().join(format!("output-files-probe-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let root = std::fs::canonicalize(&root).unwrap();
        let file = root.join("walk-brief.md");
        std::fs::write(&file, "# Walk brief\n").unwrap();
        let (data, path) = (root.join("data"), file.to_string_lossy().into_owned());
        let data = data.to_string_lossy().into_owned();

        let (code, recorded) = run(&args(&["record", &data, "thr_probe", &path]));
        assert_eq!(code, 0, "{recorded}");
        let id = recorded["ok"]["id"].as_str().unwrap().to_string();
        assert_eq!(recorded["ok"]["kind"], "md");

        let (code, detail) = run(&args(&["file", &data, "thr_probe", &id]));
        assert_eq!(code, 0, "{detail}");
        assert_eq!(detail["ok"]["previewable"], "text");
        assert_eq!(detail["ok"]["path"], path.as_str());

        let (code, refused) = run(&args(&["open", &data, "thr_probe", "out_0000000000000000"]));
        assert_eq!((code, refused["error"].as_str()), (1, Some(output_files::NOT_IN_RECORD)));
        let (code, elsewhere) = run(&args(&["file", &data, "thr_elsewhere", &id]));
        assert_eq!((code, elsewhere["error"].as_str()), (1, Some(output_files::NOT_IN_RECORD)));
        assert_eq!(run(&args(&["record"])).0, 2);

        std::fs::remove_dir_all(&root).unwrap();
    }
}
