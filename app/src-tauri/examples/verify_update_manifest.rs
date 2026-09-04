//! Verify a release's `latest.json` with the type that will parse it on the customer's Mac.
//!
//! ```text
//! cargo run --example verify_update_manifest -- \
//!     <latest.json> <artifact> <artifact>.sig <expected-url> [--current-version <v>] [--conf <tauri.conf.json>]
//! ```
//!
//! # Why this exists
//!
//! A release is four files that must agree: the archive, its `.sig`, the manifest that
//! names both, and the config compiled into the installed copy. Nothing checks that
//! agreement until an installed RichOS checks it, on a machine we cannot see, at which
//! point the only symptom is an update that never arrives.
//!
//! Every claim below is made by the vendor's own code rather than restated here:
//!
//! * the manifest is deserialized into [`tauri_plugin_updater::RemoteRelease`], which is
//!   the exact type `Updater::check` builds from the fetched body
//!   (`tauri-plugin-updater-2.11.0/src/updater.rs:1454`). A field this build cannot parse
//!   is a field the customer's build cannot parse either — including `pub_date`, which
//!   that impl requires to be RFC 3339 and rejects otherwise.
//! * the platform key is [`tauri_plugin_updater::target`], not a string assembled from
//!   `uname`. That function is `{os}-{arch}` from the plugin's own `updater_os` and
//!   `updater_arch`, so a manifest that satisfies it satisfies the lookup in `get_urls`.
//! * the signature is checked with `minisign_verify` against `plugins.updater.pubkey`, the
//!   same call `Update::download` makes before it writes a byte.
//!
//! And one thing the plugin cannot check because it never sees both halves: that the
//! `signature` string inside the manifest is the SAME signature as the `.sig` file beside
//! the archive. Publishing a manifest whose signature belongs to a previous build is a
//! release every installation refuses, and it looks perfectly well-formed.
//!
//! # A note on `darwin-aarch64` versus `darwin-aarch64-app`
//!
//! `get_urls` searches `{os}-{arch}-{installer}` first and `{os}-{arch}` second
//! (`updater.rs:608-637`), so a manifest carrying only the second key is found on the
//! second attempt and works. This example requires the key `target()` returns, which is
//! the one that always resolves.
//!
//! Exit codes: 0 everything agrees. 1 refused — something does not. 2 the inputs could
//! not be read.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::exit;

fn die(code: i32, msg: &str) -> ! {
    eprintln!("verify_update_manifest: {msg}");
    exit(code)
}

struct Args {
    manifest: PathBuf,
    artifact: PathBuf,
    sig: PathBuf,
    expected_url: String,
    current_version: Option<String>,
    conf: PathBuf,
}

fn parse_args() -> Args {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let mut positional: Vec<String> = Vec::new();
    let mut current_version = None;
    let mut conf = None;
    let mut i = 0;
    while i < argv.len() {
        match argv[i].as_str() {
            "--current-version" => {
                i += 1;
                current_version = Some(argv.get(i).cloned().unwrap_or_else(|| {
                    die(2, "--current-version needs a value")
                }));
            }
            "--conf" => {
                i += 1;
                conf = Some(PathBuf::from(argv.get(i).cloned().unwrap_or_else(|| {
                    die(2, "--conf needs a value")
                })));
            }
            other => positional.push(other.to_string()),
        }
        i += 1;
    }
    if positional.len() != 4 {
        die(
            2,
            "usage: verify_update_manifest <latest.json> <artifact> <artifact.sig> \
             <expected-url> [--current-version <v>] [--conf <tauri.conf.json>]",
        );
    }
    Args {
        manifest: PathBuf::from(&positional[0]),
        artifact: PathBuf::from(&positional[1]),
        sig: PathBuf::from(&positional[2]),
        expected_url: positional[3].clone(),
        current_version,
        conf: conf.unwrap_or_else(|| {
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tauri.conf.json")
        }),
    }
}

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
                &format!("{} has no plugins.updater.pubkey", path.display()),
            )
        })
}

fn decode(s: &str, what: &str) -> String {
    use base64::Engine;
    let raw = base64::engine::general_purpose::STANDARD
        .decode(s.trim())
        .unwrap_or_else(|e| die(2, &format!("{what} is not valid base64: {e}")));
    String::from_utf8(raw)
        .unwrap_or_else(|e| die(2, &format!("{what} is not UTF-8 once decoded: {e}")))
}

fn main() {
    let args = parse_args();
    let mut refusals: Vec<String> = Vec::new();

    // 1. THE SHAPE, judged by the type that judges it in production.
    let raw = fs::read_to_string(&args.manifest)
        .unwrap_or_else(|e| die(2, &format!("cannot read {}: {e}", args.manifest.display())));
    let value: serde_json::Value = serde_json::from_str(&raw)
        .unwrap_or_else(|e| die(1, &format!("{} is not valid JSON: {e}", args.manifest.display())));
    let release: tauri_plugin_updater::RemoteRelease = serde_json::from_value(value)
        .unwrap_or_else(|e| {
            die(
                1,
                &format!(
                    "REFUSED — {} does not deserialize as the updater's RemoteRelease: {e}\n  \
                     This is the same parse an installed RichOS performs on the fetched body.",
                    args.manifest.display()
                ),
            )
        });

    // 2. THE PLATFORM KEY, from the plugin rather than from `uname`.
    let target = tauri_plugin_updater::target()
        .unwrap_or_else(|| die(2, "tauri_plugin_updater::target() has no answer on this platform"));

    let url = match release.download_url(&target) {
        Ok(u) => Some(u.to_string()),
        Err(e) => {
            refusals.push(format!(
                "no entry for platform key '{target}': {e}. An installed RichOS on this \
                 architecture would report a manifest failure."
            ));
            None
        }
    };
    let manifest_sig = match release.signature(&target) {
        Ok(s) => Some(s.clone()),
        Err(_) => None,
    };

    if let Some(url) = &url {
        if url != &args.expected_url {
            refusals.push(format!(
                "the manifest announces {url}\n              expected {}",
                args.expected_url
            ));
        }
        if !url.starts_with("https://") {
            refusals.push(format!(
                "the download URL is not https: {url}. A release build refuses a non-https \
                 endpoint outright (config.rs:validate_endpoints) and has no reason to trust \
                 a plaintext download either."
            ));
        }
    }

    // 3. THE SIGNATURE IN THE MANIFEST IS THE SIGNATURE ON DISK. The plugin never sees
    //    both, so nothing but this compares them.
    let sig_on_disk = fs::read_to_string(&args.sig)
        .unwrap_or_else(|e| die(2, &format!("cannot read {}: {e}", args.sig.display())));
    let sig_on_disk = sig_on_disk.trim().to_string();
    if let Some(manifest_sig) = &manifest_sig {
        if manifest_sig.trim() != sig_on_disk {
            refusals.push(format!(
                "the manifest's `signature` is NOT the contents of {}. A manifest carrying \
                 another build's signature is well-formed and refused by every installation.",
                args.sig.display()
            ));
        }
    }

    // 4. THE SIGNATURE VERIFIES OVER THE ARTIFACT, under the shipped key.
    let bytes = fs::read(&args.artifact)
        .unwrap_or_else(|e| die(2, &format!("cannot read {}: {e}", args.artifact.display())));
    let pubkey_file = decode(&pubkey_from_config(&args.conf), "plugins.updater.pubkey");
    let sig_file = decode(&sig_on_disk, &format!("{}", args.sig.display()));
    let public_key = minisign_verify::PublicKey::decode(&pubkey_file)
        .unwrap_or_else(|e| die(2, &format!("plugins.updater.pubkey is not a minisign public key: {e}")));
    let signature = minisign_verify::Signature::decode(&sig_file)
        .unwrap_or_else(|e| die(2, &format!("{} is not a minisign signature: {e}", args.sig.display())));
    if let Err(e) = public_key.verify(&bytes, &signature, true) {
        refusals.push(format!(
            "the artifact does NOT verify against plugins.updater.pubkey: {e}"
        ));
    }

    // 5. THE RELEASE WOULD ACTUALLY BE OFFERED. `Updater::check` installs nothing unless
    //    `release.version > current_version` (updater.rs:575). A manifest that is correct
    //    in every other way and not strictly greater is a release nobody is offered.
    if let Some(current) = &args.current_version {
        match semver::Version::parse(current) {
            Ok(current) => {
                if !(release.version > current) {
                    refusals.push(format!(
                        "the manifest offers {} and the installed copy is {current}. The \
                         updater compares semver and only offers a STRICTLY greater version, \
                         so nobody on {current} would ever be offered this.",
                        release.version
                    ));
                }
            }
            Err(e) => refusals.push(format!("--current-version {current} is not semver: {e}")),
        }
    }

    if refusals.is_empty() {
        println!("VERIFIED: {}", args.manifest.display());
        println!("  version      : {}", release.version);
        println!("  platform key : {target}");
        println!("  url          : {}", url.unwrap_or_default());
        println!("  signature    : matches {} and verifies over {} ({} bytes)",
            args.sig.display(), args.artifact.display(), bytes.len());
        println!("  notes        : {}", release.notes.clone().unwrap_or_default());
        if let Some(current) = &args.current_version {
            println!("  offered to   : {current} (strictly lower, so the update is offered)");
        }
        return;
    }

    eprintln!();
    eprintln!("REFUSED — {} is not publishable.", args.manifest.display());
    for r in &refusals {
        eprintln!("  * {r}");
    }
    eprintln!();
    eprintln!("  Each of these is something an installed RichOS discovers instead, on a");
    eprintln!("  machine nobody is watching, as an update that silently never arrives.");
    eprintln!();
    exit(1);
}
