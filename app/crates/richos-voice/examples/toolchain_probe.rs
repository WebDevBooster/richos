//! `cargo run -p richos-voice --example toolchain_probe`
//!
//! Which whisper binary, which ggml backends and which weights would hear the CEO on this machine
//! right now — and whether any of them changed since it last listened.
//!
//! WHY AN EXAMPLE AND NOT A TEST. A test that needed a real whisper-cli would be a test that fails
//! on a machine without one, and the unit tests in `toolchain.rs` deliberately decide everything
//! from strings so they run anywhere. This is the other half: the thing you point at a REAL
//! install to watch the refusal actually fire. `richos-service toolchain` is the same question
//! asked from the Node side, against the same lock file.
//!
//! ```text
//!   RICHOS_WHISPER_BIN=/opt/homebrew/Cellar/whisper-cpp/1.8.3/bin/whisper-cli \
//!     cargo run -p richos-voice --example toolchain_probe      # watch the binary change fire
//!   RICHOS_MODEL_DIR=/tmp/tampered \
//!     cargo run -p richos-voice --example toolchain_probe      # watch the weights refuse
//! ```
//!
//! Exit 1 on a refusal, 0 otherwise — a warning is real and printed and is not a broken machine.

use richos_voice::stt::{Recognizer, SttError};
use richos_voice::toolchain;

fn main() {
    println!("lock file: {}", toolchain::lock_path().display());
    println!(
        "reference: whisper.cpp {} (the build every decode setting was measured on)",
        toolchain::reference_version().unwrap_or_else(|| "unknown".into())
    );
    println!("strict:    {}", toolchain::strict_mode());
    println!();

    match Recognizer::resolve() {
        Ok(rec) => {
            let t = rec.toolchain();
            println!("binary:     {}", rec.binary_path().display());
            println!("            version {}", t.bin_version.clone().unwrap_or_else(|| "NOT REPORTED".into()));
            println!("            sha256 {}", t.bin_sha256);
            println!("model:      {}  ({})", rec.model_path().display(), rec.model_id());
            println!(
                "            sha256 {}  ({})",
                t.model_sha256.clone().unwrap_or_else(|| "UNREADABLE".into()),
                if t.model_hash_cached { "from the shared lock cache" } else { "hashed just now" }
            );
            println!("            {}", if t.model_pinned { "pinned in model-pins.json" } else { "NOT PINNED" });
            println!();
            println!("provenance: {}", rec.provenance());
            println!("verdict:    {:?}{}", t.verdict(), if t.first_run { "  (first run — nothing to compare against)" } else { "" });
            for w in t.warnings() {
                println!("  - {w}");
            }
        }
        Err(SttError::ToolchainRefused(detail)) => {
            println!("verdict:    REFUSE");
            println!("  - {detail}");
            println!();
            println!("what the CEO would hear: {}", SttError::ToolchainRefused(String::new()).ceo_message());
            std::process::exit(1);
        }
        Err(e) => {
            println!("could not resolve: {e}");
            std::process::exit(2);
        }
    }
}
