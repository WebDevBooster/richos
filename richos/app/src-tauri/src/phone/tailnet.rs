//! **THE TAILSCALE PATH — a name the whole internet already trusts, or an honest "not yet".**
//!
//! CEO decision §61, verbatim: *"The RichOS desktop app will guide technical users (with the help
//! of crystal-clear and ultra-simple how-to screens in the app) to their Tailscale setup. That's
//! it. The Tailscale setup is where we start now."*
//!
//! The reach document's §2.3 is what this implements: *"You install Tailscale on the Mac and on
//! the phone and sign in to both with the same free account … the Mac gets a name with a
//! **publicly trusted** certificate — which would delete the sixteen taps as a side effect."*
//!
//! # This module never decides anything. It reports a state.
//!
//! Tailscale is the **user's** software, signed into the **user's** account. Every question this
//! module can ask has an answer that is not ours to change: not installed, not signed in, signed
//! in but switched off, signed in but the tailnet has not been told to issue certificates. So the
//! whole of this file is one function that turns `tailscale status --json` into one of eight
//! named states, each with a sentence HE can read. **Nothing here installs, enables, signs in or
//! retries.** §2.3's own failure mode — *"when Tailscale is off or logged out, the name stops
//! resolving including at home"* — is a state on this list, not an error.
//!
//! # What was measured, and what was NOT
//!
//! **Tailscale is not installed on this Mac.** Checked on 2026-09-18 eight ways: no
//! `/Applications/Tailscale.app`, no `tailscale` on `PATH`, nothing at `/usr/local/bin`,
//! `/opt/homebrew/bin` or inside a bundle's `Contents/MacOS`, no `~/Library/Containers/io.tailscale*`,
//! no `/var/run/tailscale*` socket, nothing in `launchctl list`, not in `brew list`, and no
//! `ts.net` resolver in `scutil --dns`. So **no output in this file was captured from a running
//! daemon**, and saying otherwise would be the exact failure the house rule about numbers is
//! about. Raised as `esc-20260918T204405Z-e25d25de`.
//!
//! What the fixtures ARE pinned to is the upstream **type declarations**, quoted verbatim from
//! `tailscale/tailscale` `main`:
//!
//! * `ipn/backend.go` — `type State int`, with `stateStrings = [...]string{"NoState",
//!   "InUseOtherUser", "NeedsLogin", "NeedsMachineAuth", "Stopped", "Starting", "Running"}`.
//!   **Seven**, and `InUseOtherUser` is the one every third-party wrapper forgets.
//! * `ipn/ipnstate/ipnstate.go` — `BackendState string` (*"is an ipn.State string value"*),
//!   `Self *PeerStatus`, and `CertDomains []string`: *"the set of DNS names for which the control
//!   plane server will assist with provisioning TLS certificates … These names are FQDNs without
//!   trailing periods."*
//! * `ipn/ipnstate/ipnstate.go` — `PeerStatus.DNSName`: *"DNSName is the Peer's FQDN. **It ends
//!   with a dot.** It has the form `host.<MagicDNSSuffix>.`"* That trailing dot is why
//!   [`origin_for`] exists rather than a `format!` at the call site.
//! * `cmd/tailscale/cli/cert.go` — `"tailscale cert [flags] <domain>"`, `--cert-file` and
//!   `--key-file` each documented as *"output cert file or `-` for stdout"*, and the two refusals
//!   this module classifies: *"HTTPS cert support is not enabled/configured for your tailnet."*
//!   and *"Tailscale is not running."*
//!
//! So the PARSER is pinned to the source of truth; the SHAPE OF A REAL RUN on this machine is
//! `unverified:` and settled by one `tailscale status --json` once it is installed. The parser is
//! deliberately written to ignore every field it was not told about, so a real daemon's much
//! larger document cannot break it by being larger.
//!
//! # Raw output is never logged, and that is borrowed rather than invented
//!
//! `richos-hq/docs/research/t3code-mobile-vs-richos-phone-2026-09-18.md` idea 7, reading T3 Code's
//! own wrapper: they classify this binary's stderr into a closed label set *"because stderr can
//! contain auth keys (`tskey-…`) and node names, and these labels are logged."* [`Diagnostic`] is
//! that closed set for us. **The raw text does not leave this module.**

use super::{PhoneError, HTTPS_PORT};
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Where a `tailscale` command line lives on macOS, best first.
///
/// Three install shapes, and they are not interchangeable
/// (<https://tailscale.com/docs/concepts/macos-variants>):
///
/// 1. **Standalone** (system extension) — installs a launcher at `/usr/local/bin/tailscale`.
/// 2. **Mac App Store** (network extension, sandboxed) — the CLI is *inside the bundle*, run as
///    `/Applications/Tailscale.app/Contents/MacOS/Tailscale`. Funnel and the SSH server are
///    documented as unavailable in this variant; **port-serving and `cert` are not on that list**,
///    which is why the path this module takes works on all three.
/// 3. **Open-source `tailscaled`** — Homebrew, so `/opt/homebrew/bin` on Apple silicon and
///    `/usr/local/bin` on Intel.
///
/// `PATH` is consulted LAST rather than first, deliberately: a `tailscale` earlier on someone's
/// `PATH` is far more likely to be a shell function, a wrapper or a shim than the real client, and
/// the three absolute paths above are the ones the vendor documents.
const CLI_CANDIDATES: [&str; 4] = [
    "/usr/local/bin/tailscale",
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/opt/homebrew/bin/tailscale",
    "/usr/bin/tailscale",
];

/// **The closed label set.** Nothing else about a failed command is ever recorded.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Diagnostic {
    /// No command line was found at any of the documented places.
    NotInstalled,
    /// The command ran and said the daemon is not up — `"Tailscale is not running."`
    DaemonUnreachable,
    /// `"HTTPS cert support is not enabled/configured for your tailnet."` A switch in the user's
    /// own Tailscale admin console, which nothing on this Mac can throw for him.
    HttpsNotEnabled,
    /// Ran, exited non-zero, and said something this module does not recognize. **The something
    /// is not kept**, because it can carry a `tskey-…` or a node name.
    Refused,
    /// The command could not be executed at all, or its output was not the shape this build reads.
    Unreadable,
}

impl Diagnostic {
    /// The one sentence that is safe to put in the Mac's own log.
    pub fn label(&self) -> &'static str {
        match self {
            Diagnostic::NotInstalled => "tailscale: not installed",
            Diagnostic::DaemonUnreachable => "tailscale: not running",
            Diagnostic::HttpsNotEnabled => "tailscale: certificates not enabled for this tailnet",
            Diagnostic::Refused => "tailscale: refused",
            Diagnostic::Unreadable => "tailscale: unreadable answer",
        }
    }

    /// Classify a command's stderr **without keeping it**. Matched on the two sentences
    /// `cmd/tailscale/cli/cert.go` actually prints, lowercased so a capitalization change upstream
    /// is not a silent reclassification.
    pub fn classify(stderr: &str) -> Diagnostic {
        let text = stderr.to_lowercase();
        if text.contains("not running") {
            Diagnostic::DaemonUnreachable
        } else if text.contains("not enabled") || text.contains("not configured") {
            Diagnostic::HttpsNotEnabled
        } else {
            Diagnostic::Refused
        }
    }
}

/// **Where the user is on the Tailscale path.** Eight states, and every one of them is somewhere a
/// real person can actually be sitting.
///
/// The brief named four — *absent / installed not signed in / signed in, name known / serving*.
/// Building it turned up more that a how-to screen has to be able to show, and each one is a
/// different thing for the user to DO:
///
/// * [`Stopped`](TailnetState::Stopped) — signed in, switched off. This is §2.3's named failure
///   mode *"including at home"*, and the fix is one click in his menu bar, not a sign-in.
/// * [`NeedsApproval`](TailnetState::NeedsApproval) — `NeedsMachineAuth`. Signed in correctly and
///   waiting for a tailnet admin to approve the device. Telling him to sign in again would be
///   wrong advice.
/// * [`CertificatesOff`](TailnetState::CertificatesOff) — **the important one.** Signed in, online,
///   name known, and `CertDomains` is empty, which is the control plane saying it will not issue a
///   certificate for this tailnet. HTTPS certificates are a switch in the Tailscale admin console
///   on the web, and **until it is on, the publicly trusted certificate this whole path exists for
///   does not exist.** A screen that says "you're all set" here would be lying.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TailnetState {
    /// No Tailscale on this Mac.
    Absent,
    /// Installed, but the daemon did not answer.
    NotRunning,
    /// Installed and running, and nobody is signed in.
    NeedsSignIn,
    /// Signed in, waiting for an administrator to approve this machine.
    NeedsApproval,
    /// Signed in and deliberately switched off. The name does not resolve, including at home.
    Stopped,
    /// Another user account on this Mac is using Tailscale. `ipn.State`'s `InUseOtherUser`.
    InUseByAnotherUser,
    /// Signed in and up, but the tailnet will not be issued certificates.
    CertificatesOff { name: String },
    /// Everything this path needs: a name, and a control plane that will certify it.
    Ready { name: String, addresses: Vec<IpAddr> },
}

impl TailnetState {
    /// The machine's tailnet name, when there is one — lowercase, no trailing dot.
    pub fn name(&self) -> Option<&str> {
        match self {
            TailnetState::CertificatesOff { name } | TailnetState::Ready { name, .. } => Some(name),
            _ => None,
        }
    }

    /// Every address the daemon says this node answers on, for the bind list and the leaf's SANs.
    pub fn addresses(&self) -> &[IpAddr] {
        match self {
            TailnetState::Ready { addresses, .. } => addresses,
            _ => &[],
        }
    }

    /// The origin the phone would pair with, and **only when it would actually work.**
    ///
    /// `CertificatesOff` deliberately answers `None` even though it holds a perfectly good name.
    /// Offering that origin would produce a certificate warning on the phone at the exact moment
    /// this path's whole promise is "no certificate warning" — and per `api_base.rs`,
    /// *"it never guesses an address and never promises a reach it has not tested."*
    pub fn origin(&self) -> Option<String> {
        match self {
            TailnetState::Ready { name, .. } => Some(origin_for(name)),
            _ => None,
        }
    }

    /// A short, stable token for the screen and for the log. Never a sentence, never translated.
    pub fn token(&self) -> &'static str {
        match self {
            TailnetState::Absent => "absent",
            TailnetState::NotRunning => "not-running",
            TailnetState::NeedsSignIn => "needs-sign-in",
            TailnetState::NeedsApproval => "needs-approval",
            TailnetState::Stopped => "stopped",
            TailnetState::InUseByAnotherUser => "other-user",
            TailnetState::CertificatesOff { .. } => "certificates-off",
            TailnetState::Ready { .. } => "ready",
        }
    }

    /// **What HE reads.** One sentence per state, each one naming the next thing to do and who has
    /// to do it, in American English, and each one true when spoken aloud as well as read — the
    /// whole app is voice-first, so a sentence that only works on a screen is half a sentence.
    ///
    /// These are a floor for Urban's how-to screens rather than a replacement for them: a screen
    /// can say more, and must never say less or something different.
    pub fn sentence(&self) -> &'static str {
        match self {
            TailnetState::Absent => {
                "Tailscale is not on this Mac. Installing it here and on your phone, and signing \
                 in to the same free account on both, is what lets you reach me when you are away \
                 from home."
            }
            TailnetState::NotRunning => {
                "Tailscale is on this Mac but it is not running right now. Open it, and I will \
                 pick it up."
            }
            TailnetState::NeedsSignIn => {
                "Tailscale is on this Mac and nobody is signed in to it. Sign in, and sign in to \
                 the same free account on your phone."
            }
            TailnetState::NeedsApproval => {
                "Tailscale is signed in and waiting for the owner of the account to approve this \
                 Mac. Nothing on this Mac can approve it for you."
            }
            TailnetState::Stopped => {
                "Tailscale is signed in and switched off, so its name for this Mac does not work \
                 anywhere, including here at home. Switch it back on."
            }
            TailnetState::InUseByAnotherUser => {
                "Tailscale is being used by a different account on this Mac, so I cannot read it \
                 from yours."
            }
            TailnetState::CertificatesOff { .. } => {
                "Tailscale has a name for this Mac, and your Tailscale account has not been told \
                 to issue certificates for it yet. That is one switch on Tailscale's own website, \
                 and until it is on, your phone would still show a warning."
            }
            TailnetState::Ready { .. } => {
                "Tailscale has a name for this Mac that your phone can reach from anywhere, and a \
                 certificate your phone already trusts. There is nothing to install on the phone."
            }
        }
    }
}

/// `mm1.tailnet-name.ts.net` becomes `https://mm1.tailnet-name.ts.net:8443`.
///
/// **Lowercased, and the trailing dot removed**, for the reason `names.rs` gives about
/// `mm1.local`: a certificate's DNS name is matched case-insensitively but an ORIGIN is compared
/// byte for byte by the browser, and two spellings would be two origins — two service workers, two
/// push subscriptions, two Home Screen icons.
///
/// **The port stays 8443.** It is the same listener on the same port as at home; only the name and
/// the certificate presented for it are new. `mod.rs` on `HTTPS_PORT`: *"the port is part of the
/// origin … changing it means re-installing the phone app."*
pub fn origin_for(name: &str) -> String {
    format!("https://{}:{}", normalize_name(name), HTTPS_PORT)
}

/// Strip the trailing dot the upstream `DNSName` comment promises, and lowercase.
pub fn normalize_name(name: &str) -> String {
    name.trim().trim_end_matches('.').to_lowercase()
}

// -------------------------------------------------------------------------------------
// reading the machine
// -------------------------------------------------------------------------------------

/// The first `tailscale` command line that exists, or `None`.
pub fn find_cli() -> Option<PathBuf> {
    for candidate in CLI_CANDIDATES {
        let path = Path::new(candidate);
        if path.is_file() {
            return Some(path.to_path_buf());
        }
    }
    // `PATH` last — see the note on [`CLI_CANDIDATES`].
    let path_var = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path_var) {
        let candidate = dir.join("tailscale");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

/// **Ask this Mac where it is on the Tailscale path.**
///
/// Returns the state and, when something went wrong, the label for it. It never returns an error:
/// every way this can fail is a state a screen has to be able to show, and a `Result` here would
/// push that decision to a caller who has less to say about it.
pub fn detect() -> (TailnetState, Option<Diagnostic>) {
    let Some(cli) = find_cli() else {
        return (TailnetState::Absent, Some(Diagnostic::NotInstalled));
    };
    detect_with(&cli)
}

/// [`detect`], against a named command line. Separated so a test can point it at a script that
/// prints a recorded document, which is the only way any of this is exercised on a Mac with no
/// Tailscale on it.
pub fn detect_with(cli: &Path) -> (TailnetState, Option<Diagnostic>) {
    let output = match Command::new(cli).arg("status").arg("--json").output() {
        Ok(o) => o,
        Err(_) => return (TailnetState::NotRunning, Some(Diagnostic::Unreadable)),
    };
    if !output.status.success() {
        // NOT the stderr text into a log line. Classified, then dropped.
        let diagnostic = Diagnostic::classify(&String::from_utf8_lossy(&output.stderr));
        return (TailnetState::NotRunning, Some(diagnostic));
    }
    match parse_status(&String::from_utf8_lossy(&output.stdout)) {
        Ok(state) => (state, None),
        Err(_) => (TailnetState::NotRunning, Some(Diagnostic::Unreadable)),
    }
}

/// The document `tailscale status --json` prints, **narrowed to the four fields this build reads**.
///
/// `#[serde(default)]` on every field and no `deny_unknown_fields`, on purpose: the real document
/// is far larger than this and gains fields between releases, and a parser that refused what it was
/// not told about would turn a Tailscale update into a RichOS outage.
#[derive(serde::Deserialize, Default)]
struct StatusDocument {
    #[serde(rename = "BackendState", default)]
    backend_state: String,
    #[serde(rename = "Self", default)]
    self_peer: Option<PeerDocument>,
    #[serde(rename = "CertDomains", default)]
    cert_domains: Vec<String>,
}

#[derive(serde::Deserialize, Default)]
struct PeerDocument {
    #[serde(rename = "DNSName", default)]
    dns_name: String,
    #[serde(rename = "TailscaleIPs", default)]
    tailscale_ips: Vec<String>,
    #[serde(rename = "Online", default)]
    online: bool,
}

/// **The whole decision, as one pure function over the document.**
///
/// Pure so it can be tested without a daemon, which on this Mac is the only way it can be tested
/// at all.
pub fn parse_status(json: &str) -> Result<TailnetState, PhoneError> {
    let document: StatusDocument = serde_json::from_str(json).map_err(|e| {
        PhoneError::Malformed(format!("tailscale status was not the expected shape: {e}"))
    })?;

    // The seven `ipn.State` spellings, from `ipn/backend.go`. An unrecognized value is treated as
    // `NotRunning` rather than as ready, because the only safe reading of a state we do not know
    // is "do not offer this path yet".
    match document.backend_state.as_str() {
        "Running" => {}
        "NeedsLogin" | "NoState" => return Ok(TailnetState::NeedsSignIn),
        "NeedsMachineAuth" => return Ok(TailnetState::NeedsApproval),
        "Stopped" => return Ok(TailnetState::Stopped),
        "InUseOtherUser" => return Ok(TailnetState::InUseByAnotherUser),
        "Starting" => return Ok(TailnetState::NotRunning),
        _ => return Ok(TailnetState::NotRunning),
    }

    let Some(peer) = document.self_peer else {
        // Running with no self is not a state the daemon should reach; it is certainly not one to
        // offer an origin from.
        return Ok(TailnetState::NotRunning);
    };
    let name = normalize_name(&peer.dns_name);
    if name.is_empty() {
        return Ok(TailnetState::NotRunning);
    }
    if !peer.online {
        // `Online` is documented as *"whether node is connected to the control plane"*. A node the
        // control plane cannot see is a node whose name other devices will not be told about.
        return Ok(TailnetState::Stopped);
    }

    // `CertDomains` is the control plane's own answer to "will I be given a certificate for this
    // name?", and it is the ONLY place that question is answered without asking for a certificate.
    // Comparing normalized on both sides: upstream says these are FQDNs *without* trailing
    // periods, but normalizing both is free and survives that changing.
    let certified = document.cert_domains.iter().any(|domain| normalize_name(domain) == name);
    if !certified {
        return Ok(TailnetState::CertificatesOff { name });
    }

    // Taken from the status document rather than from `ifconfig`, deliberately. `names.rs` reads
    // addresses out of `ifconfig -a`, and a Tailscale address WOULD show up there — it is a
    // `100.64.0.0/10` address on a `utun`, and `ipv4_addresses` filters only loopback, link-local,
    // unspecified and broadcast. But "it happens to appear in ifconfig" is an accident of one
    // variant's implementation, on a machine nobody here has. Asking the daemon which addresses it
    // assigned this node is the same answer, from the thing that knows it.
    let addresses =
        peer.tailscale_ips.iter().filter_map(|text| text.trim().parse::<IpAddr>().ok()).collect();
    Ok(TailnetState::Ready { name, addresses })
}

// -------------------------------------------------------------------------------------
// the certificate
// -------------------------------------------------------------------------------------

/// A private key as the PEM label said it was.
///
/// **Two variants, because I do not know which one `tailscale cert` emits and will not guess.**
/// An ECDSA key travels either as PKCS#8 (PEM label `PRIVATE KEY`) or as SEC1 (PEM label
/// `EC PRIVATE KEY`); rustls wants to be told which, and feeding it the wrong one fails at the
/// handshake rather than at the parse. `listen.rs`'s own TLS test exists because *"a
/// SEC1-versus-PKCS#8 mismatch … is the one thing about this handshake that is easy to get wrong
/// and impossible to see."* Reading the label is free and settles it on the machine rather than
/// in a recollection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum KeyDer {
    Pkcs8(Vec<u8>),
    Sec1(Vec<u8>),
}

/// What the listener needs in order to present this Mac's tailnet name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TailnetCert {
    /// Leaf first, then every intermediate the command handed over.
    pub chain_der: Vec<Vec<u8>>,
    pub key: KeyDer,
}

/// Every PEM block in a bundle, as `(label, DER)`.
fn pem_blocks(text: &str) -> Vec<(String, Vec<u8>)> {
    const OPEN: &str = "-----BEGIN ";
    const DASHES: &str = "-----";
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(start) = rest.find(OPEN) {
        let after = &rest[start + OPEN.len()..];
        let Some(label_end) = after.find(DASHES) else { break };
        let label = after[..label_end].trim().to_string();
        let body_start = label_end + DASHES.len();
        let end_marker = format!("-----END {label}{DASHES}");
        let Some(body_end) = after[body_start..].find(&end_marker) else { break };
        let body: String = after[body_start..body_start + body_end]
            .chars()
            .filter(|c| !c.is_whitespace())
            .collect();
        if let Ok(der) = super::unb64std(&body) {
            out.push((label, der));
        }
        rest = &after[body_start + body_end + end_marker.len()..];
    }
    out
}

/// **Ask Tailscale for the publicly trusted certificate for this Mac's tailnet name.**
///
/// `tailscale cert --cert-file - --key-file - <name>` — **both to stdout, and that is the whole
/// trick.** `cmd/tailscale/cli/cert.go` documents each flag as *"output cert file or `-` for
/// stdout"*, and asking for stdout rather than a path does two things a path cannot:
///
/// * it crosses the **Mac App Store sandbox**, where the client is a sandboxed network extension
///   and writing to a directory of our choosing is not a given, through a pipe we already own; and
/// * **the private key never touches the disk.** It goes from the pipe into memory and from there
///   into the Keychain, which is how `ca.rs` already handles every other key in this module.
///
/// Both streams arriving on one file descriptor means the two are concatenated, so the blocks are
/// sorted **by their PEM label rather than by their order** — which also makes this immune to
/// upstream ever writing the key first.
///
/// `unverified:` that this command succeeds on any variant, because there is no Tailscale on this
/// Mac. What IS verified is the parse, against a bundle built from real DER — see
/// `a_bundle_from_stdout_round_trips_to_the_bytes_it_was_built_from`.
pub fn fetch_cert(cli: &Path, name: &str, min_validity: &str) -> Result<TailnetCert, Diagnostic> {
    let name = normalize_name(name);
    let output = Command::new(cli)
        .arg("cert")
        .arg("--cert-file")
        .arg("-")
        .arg("--key-file")
        .arg("-")
        .arg("--min-validity")
        .arg(min_validity)
        .arg(&name)
        .output()
        .map_err(|_| Diagnostic::Unreadable)?;
    if !output.status.success() {
        // The two sentences this command prints — "HTTPS cert support is not enabled/configured
        // for your tailnet." and "Tailscale is not running." — are exactly what `classify` reads,
        // and the raw text goes no further than this line.
        return Err(Diagnostic::classify(&String::from_utf8_lossy(&output.stderr)));
    }
    let mut chain_der = Vec::new();
    let mut key = None;
    for (label, der) in pem_blocks(&String::from_utf8_lossy(&output.stdout)) {
        match label.as_str() {
            "CERTIFICATE" => chain_der.push(der),
            "PRIVATE KEY" => key = Some(KeyDer::Pkcs8(der)),
            "EC PRIVATE KEY" => key = Some(KeyDer::Sec1(der)),
            _ => {}
        }
    }
    match (chain_der.is_empty(), key) {
        (false, Some(key)) => Ok(TailnetCert { chain_der, key }),
        // A success exit with nothing usable in it is not something to paper over with a retry.
        _ => Err(Diagnostic::Unreadable),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::{Ipv4Addr, Ipv6Addr};

    /// **NOT CAPTURED FROM A RUNNING DAEMON.** There is no Tailscale on this Mac — see the module
    /// header for the eight checks. Every field name, every spelling and the trailing dot are
    /// transcribed from the upstream type declarations quoted there; the surrounding document is
    /// abbreviated, which is exactly the property the parser must tolerate.
    ///
    /// `unverified:` that a real `tailscale status --json` on this machine agrees. Settled by one
    /// command once the CEO installs it, and `the_parser_ignores_everything_it_was_not_told_about`
    /// below is the standing insurance against the real one being bigger.
    fn ready_document() -> String {
        r#"{
          "Version": "1.no-assertion-is-made-about-this",
          "BackendState": "Running",
          "AuthURL": "",
          "TailscaleIPs": ["100.101.102.103"],
          "Self": {
            "HostName": "MM1",
            "DNSName": "mm1.tail1a2b3c.ts.net.",
            "TailscaleIPs": ["100.101.102.103", "fd7a:115c:a1e0::1"],
            "Online": true
          },
          "CertDomains": ["mm1.tail1a2b3c.ts.net"],
          "MagicDNSSuffix": "tail1a2b3c.ts.net"
        }"#
        .to_string()
    }

    fn with(document: &str, find: &str, replace: &str) -> String {
        assert!(document.contains(find), "the fixture no longer contains {find}");
        document.replace(find, replace)
    }

    #[test]
    fn a_signed_in_mac_with_certificates_enabled_is_the_only_state_that_yields_an_origin() {
        let state = parse_status(&ready_document()).unwrap();
        assert_eq!(state.token(), "ready");
        assert_eq!(state.name(), Some("mm1.tail1a2b3c.ts.net"));
        // THE TRAILING DOT IS GONE and the port is the one the listener already uses. Both halves
        // matter: a browser compares an origin byte for byte, so `mm1.…ts.net.` and `mm1.…ts.net`
        // would be two different installed apps.
        assert_eq!(state.origin(), Some("https://mm1.tail1a2b3c.ts.net:8443".to_string()));
        assert!(!state.origin().unwrap().contains(".ts.net.:"), "the trailing dot survived");
    }

    #[test]
    fn the_addresses_come_from_the_daemon_and_both_families_survive() {
        let TailnetState::Ready { addresses, .. } = parse_status(&ready_document()).unwrap() else {
            panic!("the ready document did not parse as ready");
        };
        assert_eq!(
            addresses,
            vec![
                IpAddr::V4(Ipv4Addr::new(100, 101, 102, 103)),
                IpAddr::V6("fd7a:115c:a1e0::1".parse::<Ipv6Addr>().unwrap()),
            ]
        );
    }

    #[test]
    fn certificates_being_off_is_its_own_state_and_offers_no_origin() {
        // THE STATE THE BRIEF'S FOUR-STATE LIST DOES NOT HAVE. Signed in, online, name known, and
        // the control plane will not certify it — an admin-console switch on Tailscale's website.
        // Offering the origin here would put a certificate warning on the phone at the exact
        // moment this path's promise is that there is not one.
        let document = with(
            &ready_document(),
            r#""CertDomains": ["mm1.tail1a2b3c.ts.net"]"#,
            r#""CertDomains": []"#,
        );
        let state = parse_status(&document).unwrap();
        assert_eq!(state.token(), "certificates-off");
        assert_eq!(state.name(), Some("mm1.tail1a2b3c.ts.net"), "the name is known even here");
        assert_eq!(state.origin(), None, "an origin was offered with no certificate behind it");
        // POSITIVE CONTROL, in the same test: the SAME document with the domain restored does
        // yield an origin, so the `None` above is about `CertDomains` and not about the parser
        // having given up somewhere earlier.
        assert!(parse_status(&ready_document()).unwrap().origin().is_some());
    }

    #[test]
    fn a_certificate_for_some_other_machine_does_not_count_as_one_for_this_one() {
        // `CertDomains` is tailnet-wide in principle. Being non-empty is not the question; holding
        // THIS name is. An `is_empty()` check would have passed this and been wrong.
        let document = with(
            &ready_document(),
            r#""CertDomains": ["mm1.tail1a2b3c.ts.net"]"#,
            r#""CertDomains": ["someone-elses-laptop.tail1a2b3c.ts.net"]"#,
        );
        assert_eq!(parse_status(&document).unwrap().token(), "certificates-off");
    }

    #[test]
    fn every_one_of_the_seven_backend_states_lands_somewhere_named() {
        // From `ipn/backend.go`'s `stateStrings`, all seven, so a state added upstream shows up
        // here as a miss rather than as a silent "ready".
        let cases = [
            ("Running", "ready"),
            ("NeedsLogin", "needs-sign-in"),
            ("NoState", "needs-sign-in"),
            ("NeedsMachineAuth", "needs-approval"),
            ("Stopped", "stopped"),
            ("InUseOtherUser", "other-user"),
            ("Starting", "not-running"),
        ];
        for (backend, expected) in cases {
            let document = with(
                &ready_document(),
                r#""BackendState": "Running""#,
                &format!(r#""BackendState": "{backend}""#),
            );
            assert_eq!(
                parse_status(&document).unwrap().token(),
                expected,
                "BackendState {backend} landed in the wrong state"
            );
        }
    }

    #[test]
    fn a_backend_state_this_build_has_never_heard_of_is_not_ready() {
        // The safe reading of an unknown state is "do not offer this path", never "carry on".
        let document = with(
            &ready_document(),
            r#""BackendState": "Running""#,
            r#""BackendState": "SomethingAddedIn2027""#,
        );
        assert_eq!(parse_status(&document).unwrap().token(), "not-running");
    }

    #[test]
    fn a_node_the_control_plane_cannot_see_is_reported_as_switched_off() {
        // Sage's reach document, 2.3: "when Tailscale is off or logged out, the name stops
        // resolving including at home." Offline-but-Running is that, and it must not offer an
        // origin that will not resolve.
        let document = with(&ready_document(), r#""Online": true"#, r#""Online": false"#);
        let state = parse_status(&document).unwrap();
        assert_eq!(state.token(), "stopped");
        assert_eq!(state.origin(), None);
    }

    #[test]
    fn the_parser_ignores_everything_it_was_not_told_about() {
        // THE STANDING INSURANCE against the fixture being smaller than the real document. A real
        // `status --json` carries Peer, User, TUN, ClientVersion, Health and more, and gains
        // fields between releases. A parser that refused them would make a Tailscale update into a
        // RichOS outage.
        let document = with(
            &ready_document(),
            r#""MagicDNSSuffix": "tail1a2b3c.ts.net""#,
            r#""MagicDNSSuffix": "tail1a2b3c.ts.net",
               "Health": ["something new"],
               "Peer": {"nodekey:abc": {"HostName": "phone", "Online": true}},
               "ClientVersion": {"RunningLatest": true},
               "AFieldInventedAfterThisBuildShipped": 17"#,
        );
        assert_eq!(parse_status(&document).unwrap().token(), "ready");
    }

    #[test]
    fn a_document_that_is_not_json_is_a_refusal_rather_than_a_panic() {
        assert!(parse_status("Tailscale is not running.").is_err());
        assert!(parse_status("").is_err());
        // And an EMPTY object parses, because every field defaults — landing on "not running",
        // which is the honest answer to a daemon that told us nothing.
        assert_eq!(parse_status("{}").unwrap().token(), "not-running");
    }

    #[test]
    fn running_with_no_self_and_running_with_no_name_are_both_refused() {
        let no_self = r#"{"BackendState": "Running", "CertDomains": ["x"]}"#;
        assert_eq!(parse_status(no_self).unwrap().token(), "not-running");
        let no_name = with(
            &ready_document(),
            r#""DNSName": "mm1.tail1a2b3c.ts.net.","#,
            r#""DNSName": "","#,
        );
        assert_eq!(parse_status(&no_name).unwrap().token(), "not-running");
    }

    #[test]
    fn a_name_is_lowercased_because_an_origin_is_compared_byte_for_byte() {
        let document = with(
            &ready_document(),
            r#""DNSName": "mm1.tail1a2b3c.ts.net.""#,
            r#""DNSName": "MM1.Tail1A2B3C.ts.net.""#,
        );
        // And `CertDomains` still matches, because both sides are normalized.
        let state = parse_status(&document).unwrap();
        assert_eq!(state.token(), "ready");
        assert_eq!(state.origin(), Some("https://mm1.tail1a2b3c.ts.net:8443".to_string()));
    }

    #[test]
    fn stderr_is_classified_into_the_closed_set_and_never_kept() {
        // T3 Code's reason, adopted: "stderr can contain auth keys (`tskey-…`) and node names, and
        // these labels are logged."
        assert_eq!(
            Diagnostic::classify("Tailscale is not running."),
            Diagnostic::DaemonUnreachable
        );
        assert_eq!(
            Diagnostic::classify("HTTPS cert support is not enabled/configured for your tailnet."),
            Diagnostic::HttpsNotEnabled
        );
        let secret = "failed to start: tskey-auth-kF3xample11CNTRL-SECRETVALUE on node alex-laptop";
        let label = Diagnostic::classify(secret).label();
        assert_eq!(label, "tailscale: refused");
        // The thing this test exists for: the label carries NONE of it.
        assert!(!label.contains("tskey"), "an auth key reached a label");
        assert!(!label.contains("alex"), "a node name reached a label");
        assert!(!label.contains("SECRET"));
    }

    #[test]
    fn every_state_has_a_sentence_and_a_distinct_token() {
        let all = [
            TailnetState::Absent,
            TailnetState::NotRunning,
            TailnetState::NeedsSignIn,
            TailnetState::NeedsApproval,
            TailnetState::Stopped,
            TailnetState::InUseByAnotherUser,
            TailnetState::CertificatesOff { name: "mm1.example.ts.net".into() },
            TailnetState::Ready { name: "mm1.example.ts.net".into(), addresses: vec![] },
        ];
        let mut seen: Vec<&str> = Vec::new();
        for state in &all {
            let sentence = state.sentence();
            assert!(sentence.len() > 30, "{} has a sentence too short to help", state.token());
            assert!(sentence.ends_with('.'), "{} does not end in a full stop", state.token());
            // American English and spoken-aloud both mean no bare jargon the ear cannot hold. The
            // concrete check that is worth having: no state's sentence says "error" or "failed",
            // because seven of these eight are not failures at all.
            let lowered = sentence.to_lowercase();
            assert!(!lowered.contains("error"), "{} calls a state an error", state.token());
            assert!(!lowered.contains("failed"), "{} calls a state a failure", state.token());
            assert!(!seen.contains(&state.token()), "two states share the token {}", state.token());
            seen.push(state.token());
        }
        assert_eq!(seen.len(), 8);
    }

    #[test]
    fn only_ready_offers_an_origin() {
        // Said once, over every state, so a state added later cannot quietly start offering one.
        for state in [
            TailnetState::Absent,
            TailnetState::NotRunning,
            TailnetState::NeedsSignIn,
            TailnetState::NeedsApproval,
            TailnetState::Stopped,
            TailnetState::InUseByAnotherUser,
            TailnetState::CertificatesOff { name: "mm1.example.ts.net".into() },
        ] {
            assert_eq!(state.origin(), None, "{} offered an origin", state.token());
            assert!(state.addresses().is_empty(), "{} offered addresses", state.token());
        }
        assert!(TailnetState::Ready { name: "mm1.example.ts.net".into(), addresses: vec![] }
            .origin()
            .is_some());
    }

    /// Write an executable script that prints `stdout_text`, exits `code`, and optionally prints
    /// `stderr_text`. The ONLY way any of the command-running code in this module is exercised on
    /// a Mac with no Tailscale on it.
    fn fake_cli(tag: &str, stdout_text: &str, stderr_text: &str, code: i32) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "richos-tailnet-{tag}-{}-{}",
            std::process::id(),
            super::super::now_millis()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let script = dir.join("tailscale");
        // Single-quoted heredocs, so nothing in the payload is expanded by the shell.
        let body = format!(
            "#!/bin/sh\ncat <<'RICHOS_OUT'\n{stdout_text}\nRICHOS_OUT\ncat >&2 <<'RICHOS_ERR'\n{stderr_text}\nRICHOS_ERR\nexit {code}\n"
        );
        std::fs::write(&script, body).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        script
    }

    fn pem(label: &str, der: &[u8]) -> String {
        format!("-----BEGIN {label}-----\n{}\n-----END {label}-----", super::super::b64std(der))
    }

    #[test]
    fn a_bundle_from_stdout_round_trips_to_the_bytes_it_was_built_from() {
        // REAL DER, from this repository's own certificate authority, so the round trip is over
        // certificate bytes rather than over a string somebody typed. Both streams land on one
        // file descriptor, so the bundle is a leaf, an intermediate and a key, concatenated.
        use crate::phone::ca::PhoneCa;
        use crate::phone::names::LocalNames;
        use crate::phone::secrets::MemorySecrets;

        let dir = std::env::temp_dir()
            .join(format!("richos-tailnet-ca-{}-{}", std::process::id(), super::super::now_millis()));
        std::fs::create_dir_all(&dir).unwrap();
        let ca = PhoneCa::open(
            &dir,
            &MemorySecrets::default(),
            LocalNames {
                host: "MM1".into(),
                bonjour: "mm1.tail1a2b3c.ts.net".into(),
                addresses: vec![IpAddr::V4(Ipv4Addr::LOCALHOST)],
            },
        )
        .unwrap();

        let bundle = format!(
            "{}\n{}\n{}",
            pem("CERTIFICATE", &ca.leaf_der),
            pem("CERTIFICATE", &ca.ca_der),
            pem("PRIVATE KEY", &ca.leaf_key_pkcs8)
        );
        let cli = fake_cli("cert", &bundle, "", 0);
        let got = fetch_cert(&cli, "MM1.Tail1A2B3C.ts.net.", "720h").expect("the bundle was refused");

        // LEAF FIRST, INTERMEDIATE AFTER, byte for byte.
        assert_eq!(got.chain_der, vec![ca.leaf_der.clone(), ca.ca_der.clone()]);
        assert_eq!(got.key, KeyDer::Pkcs8(ca.leaf_key_pkcs8.clone()));
        // THE CHAIN IS WHY THIS IS A Vec. `tailscale cert` hands over the leaf AND its issuing
        // intermediate, and a public chain missing the intermediate is the classic "works in
        // curl, fails on a phone" certificate.
        assert_eq!(got.chain_der.len(), 2);

        let _ = std::fs::remove_dir_all(cli.parent().unwrap());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_key_variant_follows_the_label_rather_than_an_assumption_about_tailscale() {
        // The whole reason `KeyDer` has two variants. Same bytes, two labels, two answers — and
        // rustls fails at the HANDSHAKE rather than at the parse when this is wrong, which is why
        // it is read rather than assumed.
        let der = vec![9u8; 40];
        let sec1 = fake_cli("sec1", &format!("{}\n{}", pem("CERTIFICATE", &[1, 2, 3]), pem("EC PRIVATE KEY", &der)), "", 0);
        assert_eq!(fetch_cert(&sec1, "x.ts.net", "720h").unwrap().key, KeyDer::Sec1(der.clone()));

        let pkcs8 = fake_cli("pkcs8", &format!("{}\n{}", pem("CERTIFICATE", &[1, 2, 3]), pem("PRIVATE KEY", &der)), "", 0);
        assert_eq!(fetch_cert(&pkcs8, "x.ts.net", "720h").unwrap().key, KeyDer::Pkcs8(der));

        for path in [&sec1, &pkcs8] {
            let _ = std::fs::remove_dir_all(path.parent().unwrap());
        }
    }

    #[test]
    fn the_order_the_two_streams_arrive_in_does_not_matter() {
        // Both flags say `-`, so the two land on one file descriptor and their order is upstream's
        // to change. Sorting by label rather than by position is what makes that a non-event.
        let der = vec![7u8; 32];
        let cli = fake_cli(
            "reversed",
            &format!("{}\n{}", pem("PRIVATE KEY", &der), pem("CERTIFICATE", &[4, 5, 6])),
            "",
            0,
        );
        let got = fetch_cert(&cli, "x.ts.net", "720h").unwrap();
        assert_eq!(got.chain_der, vec![vec![4, 5, 6]]);
        assert_eq!(got.key, KeyDer::Pkcs8(der));
        let _ = std::fs::remove_dir_all(cli.parent().unwrap());
    }

    #[test]
    fn the_two_refusals_this_command_actually_prints_become_their_own_labels() {
        // From `cmd/tailscale/cli/cert.go`, the two sentences quoted in the module header.
        let off = fake_cli(
            "off",
            "",
            "HTTPS cert support is not enabled/configured for your tailnet.",
            1,
        );
        assert_eq!(fetch_cert(&off, "x.ts.net", "720h"), Err(Diagnostic::HttpsNotEnabled));

        let down = fake_cli("down", "", "Tailscale is not running.", 1);
        assert_eq!(fetch_cert(&down, "x.ts.net", "720h"), Err(Diagnostic::DaemonUnreachable));

        // A ZERO EXIT WITH NOTHING USABLE IN IT IS STILL A REFUSAL. Succeeding and returning a
        // certificate are two different things, and treating the first as the second is how an
        // empty chain reaches rustls.
        let empty = fake_cli("empty", "nothing resembling a certificate", "", 0);
        assert_eq!(fetch_cert(&empty, "x.ts.net", "720h"), Err(Diagnostic::Unreadable));

        // A CERTIFICATE WITH NO KEY IS ALSO A REFUSAL, not half an answer.
        let keyless = fake_cli("keyless", &pem("CERTIFICATE", &[1, 2, 3]), "", 0);
        assert_eq!(fetch_cert(&keyless, "x.ts.net", "720h"), Err(Diagnostic::Unreadable));

        for path in [&off, &down, &empty, &keyless] {
            let _ = std::fs::remove_dir_all(path.parent().unwrap());
        }
    }

    #[test]
    fn detection_reads_a_recorded_document_through_a_real_subprocess() {
        // `parse_status` is tested directly everywhere else; this is the one test that proves the
        // COMMAND path — argv, stdout capture, exit code — rather than the parser.
        let cli = fake_cli("status", &ready_document(), "", 0);
        let (state, diagnostic) = detect_with(&cli);
        assert_eq!(state.token(), "ready");
        assert_eq!(diagnostic, None);
        assert_eq!(state.origin(), Some("https://mm1.tail1a2b3c.ts.net:8443".to_string()));

        // And a daemon that is down is the label, with the raw text dropped.
        let down = fake_cli("statusdown", "", "Tailscale is not running.", 1);
        let (state, diagnostic) = detect_with(&down);
        assert_eq!(state.token(), "not-running");
        assert_eq!(diagnostic, Some(Diagnostic::DaemonUnreachable));

        for path in [&cli, &down] {
            let _ = std::fs::remove_dir_all(path.parent().unwrap());
        }
    }

    #[test]
    fn a_command_line_that_is_not_there_is_a_state_rather_than_a_failure() {
        // TRUE ON THIS MACHINE TODAY, which is why it is worth asserting here rather than only in
        // the record: nothing panics, nothing returns `Err`, and no origin is offered.
        let (state, diagnostic) = detect_with(Path::new("/nonexistent/tailscale"));
        assert_eq!(state.token(), "not-running");
        assert_eq!(diagnostic, Some(Diagnostic::Unreadable));
        assert_eq!(state.origin(), None);
    }
}
