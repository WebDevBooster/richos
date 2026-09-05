//! Print a content-free digest of the projection a ledger file replays into.
//!
//! ```text
//! cargo run -p richos-core --example ledger_projection_digest -- <ledger.jsonl> [more...]
//! ```
//!
//! Run it with two different builds of this crate against the same file and `diff` the
//! outputs. Identical output means the two builds read that customer's history into
//! exactly the same conversation — which is the only honest way to claim that a change to
//! the reader left every existing ledger exactly as readable as it was.
//!
//! It never prints a customer's words: every field that can hold prose is emitted as
//! `<sha256>:<byte length>`, and the file is copied to scratch before it is opened, so the
//! original is only ever read. The digest itself lives in
//! `tests/support/ledger_digest.rs` — one implementation, shared with
//! `tests/ledger_forward_compat_tests.rs`, so a golden captured here is the same artifact
//! that suite compares against.

#[path = "../tests/support/ledger_digest.rs"]
mod ledger_digest;

use std::path::PathBuf;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!(
            "usage: ledger_projection_digest <ledger.jsonl> [more...]\n\
             prints a content-free digest of the projection each file replays into"
        );
        std::process::exit(2);
    }
    let scratch = std::env::temp_dir().join(format!("richos-ledger-digest-{}", std::process::id()));
    std::fs::create_dir_all(&scratch).expect("create scratch dir");

    for (i, arg) in args.iter().enumerate() {
        let src = PathBuf::from(arg);
        if i > 0 {
            println!();
        }
        println!("=== ledger {} ===", ledger_digest::label(&src));
        match ledger_digest::digest_ledger(&src, &scratch.join(format!("copy-{i}.jsonl"))) {
            Ok(lines) => {
                for l in lines {
                    println!("{l}");
                }
            }
            Err(e) => println!("UNREADABLE = {e}"),
        }
    }
    let _ = std::fs::remove_dir_all(&scratch);
}
