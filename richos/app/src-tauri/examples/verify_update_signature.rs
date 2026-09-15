//! Verify an update artifact against the public key THIS REPOSITORY SHIPS.
//!
//! ```text
//! cargo run --example verify_update_signature -- <artifact> <artifact>.sig [<tauri.conf.json>]
//! ```
//!
//! # Why this exists
//!
//! `package-app.sh` produces `RichOS.app.tar.gz` and a minisign `.sig` beside it. Up to the
//! moment someone downloads it, nothing has ever checked that those two files agree — the
//! signer's exit code says a signature was WRITTEN, not that it VERIFIES, and it certainly
//! does not say the key that wrote it is the key `tauri.conf.json` compiles into the app. A
//! release signed with the wrong key is indistinguishable from a correct one until it
//! reaches a customer, where it fails as a security refusal on a machine we cannot see.
//!
//! So this reads the pubkey OUT OF `tauri.conf.json` — the same string
//! `tauri-plugin-updater` gets — and runs the same `minisign_verify` call the updater runs
//! (`tauri-plugin-updater-2.11.0/src/updater.rs:verify_signature`, reached from
//! `Update::download` before a single byte is installed).
//!
//! IT IS NOT AN INDEPENDENT IMPLEMENTATION AND DOES NOT CLAIM TO BE. It is the same crate,
//! deliberately: a second implementation of Ed25519 would be a thing that can disagree with
//! the one that matters. What it buys is that the check happens BEFORE publication rather
//! than on the CEO's Mac, and that it is run against the shipped configuration rather than
//! against whatever key happened to be in the environment.
//!
//! Exit codes: 0 verified. 1 refused — the artifact and the signature do not agree under
//! the shipped key. 2 the inputs could not be read.

use std::fs;
use std::path::Path;
use std::process::exit;

fn die(code: i32, msg: &str) -> ! {
    eprintln!("verify_update_signature: {msg}");
    exit(code)
}

/// The `plugins.updater.pubkey` string, read out of the config the app is built from.
fn pubkey_from_config(path: &Path) -> String {
    let raw = fs::read_to_string(path)
        .unwrap_or_else(|e| die(2, &format!("cannot read {}: {e}", path.display())));
    let json: serde_json::Value = serde_json::from_str(&raw)
        .unwrap_or_else(|e| die(2, &format!("{} is not valid JSON: {e}", path.display())));
    json.get("plugins")
        .and_then(|p| p.get("updater"))
        .and_then(|u| u.get("pubkey"))
        .and_then(|k| k.as_str())
        .map(|s| s.to_string())
        .unwrap_or_else(|| {
            die(
                2,
                &format!(
                    "{} has no plugins.updater.pubkey — there is nothing to verify against",
                    path.display()
                ),
            )
        })
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() < 2 {
        die(
            2,
            "usage: verify_update_signature <artifact> <artifact.sig> [tauri.conf.json]",
        );
    }
    let artifact = Path::new(&args[0]);
    let sig_path = Path::new(&args[1]);
    let conf = if args.len() > 2 {
        Path::new(&args[2]).to_path_buf()
    } else {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tauri.conf.json")
    };

    let bytes = fs::read(artifact)
        .unwrap_or_else(|e| die(2, &format!("cannot read {}: {e}", artifact.display())));
    let sig_b64 = fs::read_to_string(sig_path)
        .unwrap_or_else(|e| die(2, &format!("cannot read {}: {e}", sig_path.display())));

    // Both the pubkey in the config and the `.sig` on disk are base64 of a minisign FILE —
    // the untrusted-comment line plus the key/signature line. That double encoding is the
    // vendor's format, not ours, and is why both are decoded before being parsed.
    let pubkey_b64 = pubkey_from_config(&conf);
    let pubkey_file = decode(&pubkey_b64, "plugins.updater.pubkey");
    let sig_file = decode(sig_b64.trim(), &format!("{}", sig_path.display()));

    let public_key = minisign_verify::PublicKey::decode(&pubkey_file)
        .unwrap_or_else(|e| die(2, &format!("plugins.updater.pubkey is not a minisign public key: {e}")));
    let signature = minisign_verify::Signature::decode(&sig_file)
        .unwrap_or_else(|e| die(2, &format!("{} is not a minisign signature: {e}", sig_path.display())));

    match public_key.verify(&bytes, &signature, true) {
        Ok(()) => {
            println!(
                "VERIFIED: {} ({} bytes) is signed by the key in {}",
                artifact.display(),
                bytes.len(),
                conf.display()
            );
        }
        Err(e) => {
            // The refusal is the valuable outcome, so it is spelled out rather than dumped.
            eprintln!();
            eprintln!("REFUSED — {} does NOT verify against the shipped key.", artifact.display());
            eprintln!("  minisign says: {e}");
            eprintln!("  artifact     : {} bytes", bytes.len());
            eprintln!("  signature    : {}", sig_path.display());
            eprintln!("  public key   : plugins.updater.pubkey in {}", conf.display());
            eprintln!();
            eprintln!("  This is exactly what the updater does on the CEO's machine, before");
            eprintln!("  a single byte is installed. Publishing this pair would ship a release");
            eprintln!("  that every installation refuses.");
            eprintln!();
            exit(1);
        }
    }
}

fn decode(s: &str, what: &str) -> String {
    use base64::Engine;
    let raw = base64::engine::general_purpose::STANDARD
        .decode(s.trim())
        .unwrap_or_else(|e| die(2, &format!("{what} is not valid base64: {e}")));
    String::from_utf8(raw).unwrap_or_else(|e| die(2, &format!("{what} is not UTF-8 once decoded: {e}")))
}
