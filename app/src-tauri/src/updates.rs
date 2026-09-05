//! THE UPDATE PATH — check, download, verify, install, relaunch.
//!
//! WHAT THIS REPLACES: nothing. Before this module there was no updater of any kind in
//! RichOS — no `tauri-plugin-updater`, no Sparkle, no manifest, no signing key. The CEO's
//! *"automatically download and install whatever the user needs"* rested on zero
//! infrastructure, and so did every future signed release.
//!
//! # Why the flow lives in Rust and not in the webview
//!
//! `tauri-plugin-updater` ships a JavaScript API, and the obvious wiring is to let the page
//! call `plugin:updater|check` and `plugin:updater|download_and_install` directly. This
//! module does NOT do that, for three reasons that are specific to this app:
//!
//!   1. `app/ui` has no bundler and no npm step — it is plain script tags — so the plugin's
//!      JS package could only be reached through hand-rolled `invoke("plugin:updater|…")`
//!      calls against an undocumented rid-passing protocol. A typo there is a runtime
//!      failure in the one flow that must not fail quietly.
//!   2. Every other capability in this shell is a Rust command behind `window.RichBridge`
//!      (`main.rs`'s `invoke_handler`), which is what lets `mock.js` drive the whole UI in a
//!      browser with no Tauri at all. An updater that broke that rule would be the only
//!      surface the browser suites could not reach.
//!   3. **It keeps the webview's authority at zero.** Because the page never calls a
//!      `plugin:updater|*` command, `capabilities/default.json` does not grant one, and a
//!      compromised or mistaken frontend cannot start a download or an install by itself.
//!      That is a smaller attack surface than `updater:default`, not a larger one.
//!
//! # What is actually load-bearing here, and what is not
//!
//! **The signature check is not ours and we do not re-implement it.** `Update::download`
//! calls `verify_signature(&buffer, &self.signature, &config.pubkey)` — minisign, via
//! `minisign_verify` — BEFORE returning the bytes, and `download_and_install` cannot reach
//! `install` if that fails (tauri-plugin-updater 2.11.0, `src/updater.rs:739`). So the only
//! thing this file can get wrong about verification is to swallow the error, which is why
//! `Failure::classify` gives minisign errors their own kind and their own headline, and why
//! `app/scripts/updater-e2e.sh` case T proves the refusal end to end rather than asserting
//! it.
//!
//! # The state machine
//!
//! ```text
//!  Unconfigured ─── (no update server chosen yet; a stated fallback, not a failure)
//!
//!  Idle ──check──▶ Checking ──▶ UpToDate
//!                           └─▶ Available ──install──▶ Downloading ──▶ Installing ──▶ Ready
//!                                                              └────────┬───────────┘
//!  any ──error──▶ Failed(kind)                                          │
//!                                                       Ready ──relaunch──▶ (process replaced)
//! ```
//!
//! Every transition is emitted to the webview as `rich://update`, and every transition is
//! also readable on demand with the `update_state` command — a UI that missed an event is
//! never left describing a state the app is not in.
//!
//! # Installing is DELIBERATELY not automatic, and this is the reason
//!
//! The check is automatic and silent-until-it-finds-something; the install is a button. On
//! macOS `Update::install` deletes and replaces the running `.app` bundle in place
//! (`updater.rs:1288`). RichOS holds a `claude-agent-acp` child process as a compute lease,
//! and the session-continuity design's first structural invariant is that the lease is never
//! swapped mid-turn (`docs/plans/richos-session-continuity-2026-08-24.md` §3.1). Replacing
//! the bundle those processes were launched from, without asking, is that invariant broken
//! by a background thread. So: RichOS finds the update on its own and says so; the CEO
//! decides when the machine underneath him changes.
//!
//! **Mode 1 — install with no click at all — is still not built here, and §26 is why.** That
//! ruling's own words: mode 1 is *"download and stage silently, then apply at a SAFE MOMENT
//! ... Building the staging and the safe-moment policy IS the work; removing the button is
//! the trivial part."* This file builds the SAFE-MOMENT half and nothing else. Nothing below
//! ever installs something the CEO did not press.
//!
//! # THE WORK GATE — nothing about an update may get in the way of finishing work
//!
//! **The defect this closes, found by the CEO on 2026-09-05 and verified in this file rather
//! than assumed.** He asked whether the updater could destroy work in flight. It could, and
//! it was three missing checks: `install()` took the pending update and began downloading
//! with no test of turn state; `ui/updates.js` wired the Install button straight to the
//! command, so nothing was disabled and nothing warned; and `update_relaunch()` was
//! `app.restart()` and nothing else — two lines, no condition. **Pressed mid-turn, the third
//! one replaces the process while a `claude` child is mid-answer.**
//!
//! **His rulings, and each one is a line of code below rather than a sentiment.**
//!
//!   * *"Yes, offer to wait and install when all work is finished."* **ALL WORK**, not the
//!     current turn — RichOS runs workers alongside the conversation, and a worker still
//!     running is still work. [`richos_core::work_gate`] holds that decision.
//!   * *"The update is not important enough to get in the way of finishing work."* So the
//!     DOWNLOAD waits too, not only the restart. Even where staging is technically harmless
//!     it competes for bandwidth and for attention, and a progress bar moving while he is
//!     mid-thought is getting in the way.
//!   * *"We don't even show the update button/notification if the RichOS app currently has
//!     active things running."* Absent, not dimmed — the precedent is this product's own
//!     `voice_readiness`, where a machine that cannot hear REMOVES the talk button rather
//!     than disabling it, because *"the affordance appears only where it functions."*
//!   * *"Instead of a regular update button, they'd get some other visual cue but not an
//!     actionable thing."* [`UpdateView::busy`] plus [`UpdateView::busy_reason`] is what the
//!     surface builds that cue from. Hiding the ACTION is the ruling; hiding the FACT would
//!     be §26's *"an update nobody discovers is the same as no updater at all"*.
//!
//! **FAIL TOWARD WAITING.** If the gate cannot establish whether work is running, it waits.
//! It never resolves ambiguity in favor of installing — a delayed update is a nuisance and
//! destroyed work is the defect.
//!
//! **WHAT THE GATE CANNOT DO, said here rather than discovered later.** It stops an install
//! and a restart from STARTING while work is live. It cannot ABORT a download already in
//! flight: `Update::download_and_install` takes no cancellation token
//! (tauri-plugin-updater 2.11.0), so once the bytes are moving they finish. A turn that
//! begins mid-download therefore rides it out, and the protection that matters — the
//! process is not replaced — still holds at the relaunch. Building a cancellable download
//! means a vendor change and it is not quietly half-done here.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use richos_core::work_gate::{self, Liveness, WorkSources, WorkVerdict};
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_updater::UpdaterExt;

/// The one event the webview subscribes to. Same `rich://` family as every other live
/// channel in this shell (`app/STREAMING.md`).
pub const EVENT_UPDATE: &str = "rich://update";

/// The host in `tauri.conf.json`'s committed `plugins.updater.endpoints`.
///
/// `.invalid` is reserved by RFC 2606 and can never resolve, and that is the point: WHERE
/// RICHOS UPDATES ARE HOSTED IS NOT AN ENGINEERING DECISION and has not been made. A
/// plausible-looking hostname committed here would fail as a DNS error six months from now
/// and read as a bug; this fails as `UpdateState::Unconfigured`, which says the true thing
/// in the UI: no update server has been chosen yet.
pub const PLACEHOLDER_ENDPOINT_HOST: &str = "updates.richos.invalid";

/// Point this build at a different manifest, for a staging channel or for
/// `app/scripts/updater-e2e.sh`.
///
/// It is not a back door. The public key is compiled into the binary from
/// `tauri.conf.json`, and `Update::download` verifies every byte against it before a single
/// byte is installed — so an attacker who can set this variable can make the updater fetch
/// a manifest and can make it REFUSE, and cannot make it install anything we did not sign.
/// The endpoint in force is reported to the UI in every payload (`endpoint`), so a build
/// pointed somewhere unusual says so on screen rather than in a log nobody opens.
pub const ENDPOINT_ENV: &str = "RICHOS_UPDATE_ENDPOINT";

/// Headless end-to-end mode; see `app/scripts/updater-e2e.sh`.
pub const SELFTEST_ENV: &str = "RICHOS_UPDATE_SELFTEST";

// ---------------------------------------------------------------------------------------
// The view the webview renders
// ---------------------------------------------------------------------------------------

/// Why an update attempt stopped, in the CEO's language and in the operator's.
///
/// `kind` is the machine-readable discriminant the UI styles on; `headline` is the sentence
/// a non-technical CEO reads; `detail` is the vendor's own error text, kept verbatim so a
/// support conversation is not a game of telephone. The UI shows the headline always and
/// the detail behind a disclosure — an error that hides its cause is how a five-minute
/// diagnosis becomes a week.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Failure {
    pub kind: &'static str,
    pub headline: String,
    pub detail: String,
}

impl Failure {
    /// Map a plugin error onto the five things that can actually go wrong, plus a catch-all.
    ///
    /// `tauri_plugin_updater::Error` is `#[non_exhaustive]`, so the wildcard arm is required
    /// rather than lazy — but it is deliberately LAST and deliberately named "other", so a
    /// new vendor variant surfaces as an unclassified failure with its text intact instead
    /// of being silently folded into a neighbour.
    pub fn classify(err: &tauri_plugin_updater::Error) -> Self {
        use tauri_plugin_updater::Error as E;
        let detail = err.to_string();
        let (kind, headline) = match err {
            // THE ONE THAT MATTERS. minisign said no: the bytes on the wire are not the
            // bytes we signed. There is no "retry" for this and the UI must not offer one.
            E::Minisign(_) | E::Base64(_) | E::SignatureUtf8(_) => (
                "signature",
                "This download was not signed by RichOS, so it was not installed.",
            ),
            E::Reqwest(e) if e.is_connect() || e.is_timeout() => (
                "offline",
                "RichOS could not reach the update server. Check your internet connection.",
            ),
            E::Reqwest(_) | E::Network(_) => (
                "network",
                "The download did not finish. Nothing was installed.",
            ),
            E::ReleaseNotFound
            | E::Serialization(_)
            | E::Semver(_)
            | E::TargetNotFound(_)
            | E::TargetsNotFound(_)
            | E::UnsupportedArch
            | E::UnsupportedOs => (
                "manifest",
                "The update server answered, but not with something RichOS understands.",
            ),
            E::Io(_)
            | E::AuthenticationFailed
            | E::FailedToDetermineExtractPath
            | E::TempDirNotFound
            | E::BinaryNotFoundInArchive
            | E::InvalidUpdaterFormat
            | E::PackageInstallFailed => (
                "install",
                "The update downloaded and verified, but could not be put in place.",
            ),
            E::EmptyEndpoints | E::InsecureTransportProtocol | E::UrlParse(_) => (
                "configuration",
                "This build of RichOS has no usable update server configured.",
            ),
            _ => ("other", "The update did not complete."),
        };
        Failure {
            kind,
            headline: headline.to_string(),
            detail,
        }
    }
}

/// Everything the update surface needs to draw itself, in one payload.
///
/// One flat struct rather than a tagged union because it is also the ANSWER to
/// `update_state`, and a UI that reconnects mid-download has to be able to paint the bar at
/// the right place from a single read.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateView {
    /// `unconfigured` | `idle` | `checking` | `upToDate` | `available` | `downloading`
    /// | `installing` | `ready` | `failed`
    pub state: &'static str,
    /// The version running right now — `tauri.conf.json`'s `version`, via the package.
    pub current_version: String,
    /// The version the manifest offers, once a check has found one.
    pub available_version: Option<String>,
    /// The manifest's `notes`, shown verbatim. Never invented.
    pub notes: Option<String>,
    /// The manifest's `pub_date`, RFC 3339, as the server sent it.
    pub pub_date: Option<String>,
    pub downloaded_bytes: u64,
    /// `None` when the server sent no `Content-Length` — in which case the UI shows bytes
    /// and NOT a percentage, because a progress bar with an invented denominator is a lie
    /// that looks like a measurement.
    pub total_bytes: Option<u64>,
    pub percent: Option<u8>,
    pub failure: Option<Failure>,
    /// The endpoint actually in force, so a build pointed at a staging manifest says so.
    pub endpoint: String,
    /// Whether that endpoint is the committed placeholder.
    pub endpoint_is_placeholder: bool,
    /// Wall-clock milliseconds of the last completed check, or `None` for "never checked".
    /// The CEO must be able to see THAT it checked, not only what it found.
    pub checked_at: Option<u64>,

    // ---- the work gate (CEO, 2026-09-05) ----------------------------------------------
    /// **RichOS is doing something, so the update must not act and must not be offered.**
    ///
    /// It is on the view rather than behind its own command for one reason: the view is
    /// already *"everything the update surface needs to draw itself, in one payload"*, and a
    /// surface that had to combine two payloads could paint an Install button from a fresh
    /// update state and a stale work state. There is one answer and it arrives with
    /// everything else.
    pub busy: bool,
    /// WHAT is running, in the CEO's words — "Rich is working on your last message.",
    /// "2 workers are still running." `None` when nothing is.
    ///
    /// A blocking verdict ALWAYS carries one (`work_gate`'s
    /// `no_blocking_verdict_is_ever_silent` walks all 27 combinations to prove it), because
    /// a control that vanishes with no explanation is indistinguishable from a broken one.
    pub busy_reason: Option<String>,
    /// What the gate could NOT establish, one clause each — rendered as well as the reason.
    ///
    /// *"Never claim to have waited for something you did not check."* The live case is an
    /// app with no compute lease: it has no session id, so it cannot see workers, so it says
    /// so instead of implying it looked.
    pub unchecked: Vec<String>,
    /// When this update first became something the CEO could act on — the moment the view
    /// entered `available`, carried through `ready`.
    ///
    /// **It exists because the gate can hide the control for a long time.** RichOS is built
    /// to run workers for stretches, so "ready since Tuesday" is honest and a silent
    /// indefinite wait is not. Cleared by `clear_attempt`, so a fresh check restarts it
    /// rather than ageing an update that was replaced.
    pub ready_since: Option<u64>,
}

impl UpdateView {
    fn new(current_version: String, endpoint: String, placeholder: bool) -> Self {
        UpdateView {
            state: if placeholder { "unconfigured" } else { "idle" },
            current_version,
            available_version: None,
            notes: None,
            pub_date: None,
            downloaded_bytes: 0,
            total_bytes: None,
            percent: None,
            failure: None,
            endpoint,
            endpoint_is_placeholder: placeholder,
            checked_at: None,
            busy: false,
            busy_reason: None,
            unchecked: Vec::new(),
            ready_since: None,
        }
    }

    /// Reset everything a previous attempt left behind, keeping only what is still true.
    fn clear_attempt(&mut self) {
        self.available_version = None;
        self.notes = None;
        self.pub_date = None;
        self.downloaded_bytes = 0;
        self.total_bytes = None;
        self.percent = None;
        self.failure = None;
        // A new attempt is a new update. Carrying the old `ready_since` forward would age a
        // version that is no longer the one on offer, which is the one thing this field
        // exists to state accurately.
        self.ready_since = None;
    }
}

/// The managed state: one view, plus the `Update` handle a successful check produced.
///
/// The handle is kept so that "install" does not re-check. Re-checking between the CEO
/// reading "0.1.1 is available" and pressing the button would mean the thing he agreed to
/// install is not necessarily the thing that gets installed.
pub struct Updates {
    view: Mutex<UpdateView>,
    pending: Mutex<Option<tauri_plugin_updater::Update>>,
}

impl Updates {
    pub fn snapshot(&self) -> UpdateView {
        self.view.lock().expect("update view lock").clone()
    }
}

// ---------------------------------------------------------------------------------------
// Wiring
// ---------------------------------------------------------------------------------------

/// The endpoint this process will use, and whether it is the committed placeholder.
///
/// Read once per call rather than cached, so `updater-e2e.sh` can start two processes from
/// the same bundle with different endpoints.
fn resolve_endpoint(app: &AppHandle) -> (String, bool) {
    if let Ok(env) = std::env::var(ENDPOINT_ENV) {
        let env = env.trim().to_string();
        if !env.is_empty() {
            let placeholder = env.contains(PLACEHOLDER_ENDPOINT_HOST);
            return (env, placeholder);
        }
    }
    // Fall back to what the config declares. `tauri::Config` does not expose plugin config
    // as a typed value, so this reads the same JSON the plugin reads.
    let configured = app
        .config()
        .plugins
        .0
        .get("updater")
        .and_then(|v| v.get("endpoints"))
        .and_then(|v| v.as_array())
        .and_then(|a| a.first())
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let placeholder = configured.is_empty() || configured.contains(PLACEHOLDER_ENDPOINT_HOST);
    (configured, placeholder)
}

/// Install the update state. Pure — no I/O, no network, nothing that can fail — so it is
/// safe to call at any point in `setup` without moving what is already first there.
pub fn init(app: &AppHandle) {
    let (endpoint, placeholder) = resolve_endpoint(app);
    let version = app.package_info().version.to_string();
    app.manage(Updates {
        view: Mutex::new(UpdateView::new(version, endpoint, placeholder)),
        pending: Mutex::new(None),
    });
}

/// Write a transition and tell the webview. Every state change in this file goes through
/// here, so there is exactly one place an emit could be forgotten.
fn transition<F: FnOnce(&mut UpdateView)>(app: &AppHandle, f: F) -> UpdateView {
    let state = app.state::<Updates>();
    let view = {
        let mut guard = state.view.lock().expect("update view lock");
        f(&mut guard);
        guard.clone()
    };
    // Best-effort, exactly like every other emitter in this shell: a missing or closed
    // webview must never stall the update path.
    let _ = app.emit(EVENT_UPDATE, view.clone());
    view
}

fn now_millis() -> u64 {
    richos_core::util::now_millis()
}

// ---------------------------------------------------------------------------------------
// The three operations
// ---------------------------------------------------------------------------------------

/// Ask the endpoint what it has. Never installs, never downloads a byte of payload.
pub async fn check(app: &AppHandle) -> UpdateView {
    let (endpoint, placeholder) = resolve_endpoint(app);

    if placeholder {
        return transition(app, |v| {
            v.clear_attempt();
            v.state = "unconfigured";
            v.endpoint = endpoint.clone();
            v.endpoint_is_placeholder = true;
        });
    }

    transition(app, |v| {
        v.clear_attempt();
        v.state = "checking";
        v.endpoint = endpoint.clone();
        v.endpoint_is_placeholder = false;
    });

    let parsed = match tauri::Url::parse(&endpoint) {
        Ok(url) => url,
        Err(e) => {
            // Not routed through `Failure::classify`: the endpoint never became a URL, so
            // there is no plugin error to classify and inventing one would misreport where
            // the fault is. This is a configuration fault and says so.
            let detail = format!("{endpoint}: {e}");
            return transition(app, |v| {
                v.state = "failed";
                v.failure = Some(Failure {
                    kind: "configuration",
                    headline: "This build of RichOS has no usable update server configured."
                        .to_string(),
                    detail,
                });
            });
        }
    };

    let updater = match app
        .updater_builder()
        .endpoints(vec![parsed])
        .and_then(|b| b.build())
    {
        Ok(u) => u,
        Err(e) => {
            let failure = Failure::classify(&e);
            return transition(app, |v| {
                v.state = "failed";
                v.failure = Some(failure);
            });
        }
    };

    match updater.check().await {
        Ok(Some(update)) => {
            let version = update.version.clone();
            let notes = update.body.clone();
            // The manifest's own `pub_date` string, not a re-formatting of the parsed
            // `OffsetDateTime`. `Update::date` is already proof it parsed; passing the
            // server's text through means the date on screen is the date in the file, with
            // no chance of a formatter quietly shifting a zone.
            let date = update
                .raw_json
                .get("pub_date")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            *app.state::<Updates>().pending.lock().expect("pending lock") = Some(update);
            transition(app, |v| {
                v.state = "available";
                v.available_version = Some(version);
                v.notes = notes;
                v.pub_date = date;
                v.checked_at = Some(now_millis());
                // FROM NOW, not from the manifest's `pub_date`. The question this answers is
                // "how long has RichOS been unable to offer me this", which starts when this
                // install learned about it — a version published in March that this machine
                // met an hour ago has been waiting an hour.
                v.ready_since = Some(now_millis());
            })
        }
        Ok(None) => {
            *app.state::<Updates>().pending.lock().expect("pending lock") = None;
            transition(app, |v| {
                v.state = "upToDate";
                v.checked_at = Some(now_millis());
            })
        }
        Err(e) => {
            let failure = Failure::classify(&e);
            transition(app, |v| {
                v.state = "failed";
                v.failure = Some(failure);
                v.checked_at = Some(now_millis());
            })
        }
    }
}

/// Download the update the last check found, verify it, and put it in place.
///
/// Returns with `state == "ready"` — the new bundle is on disk and the OLD process is still
/// running. On macOS that is not a limitation to work around, it is the contract:
/// `Update::install`'s own doc says *"you need to relaunch the app to run the newly install
/// version"*. `relaunch` below is that step, and it is a separate button because the CEO
/// may be mid-conversation.
pub async fn install(app: &AppHandle) -> UpdateView {
    // THE GATE, BEFORE THE PENDING UPDATE IS EVEN LOOKED AT.
    //
    // `updates.js` removes the Install control while `busy`, so on the shipping surface this
    // is normally unreachable — and it is here anyway, for the same reason
    // `start_voice_capture` still refuses after `main.js` has hidden the talk button: hiding
    // an affordance is the affordance half of a fix and never the whole of it. What reaches
    // it is the RACE — he pressed while idle and a turn, a proactive message or a worker
    // started in the milliseconds before the command landed — plus anything that ever calls
    // this function from somewhere other than that button.
    //
    // It REFUSES rather than queueing, and the distinction is the CEO's own: he still
    // presses it, and the control comes back when his work is finished. A queued install
    // that fired by itself later would be mode 1, which §26 rules is a design session of its
    // own and which this file does not invent.
    let verdict = refresh_work_verdict(app);
    if verdict.busy {
        // The state is UNCHANGED — still `available`, still holding the same pending update,
        // with `busy` now true. Nothing was downloaded, nothing was lost, and the surface
        // reads the reason off the same payload it already had.
        return app.state::<Updates>().snapshot();
    }

    let pending = {
        let state = app.state::<Updates>();
        let guard = state.pending.lock().expect("pending lock");
        guard.clone()
    };

    let Some(update) = pending else {
        return transition(app, |v| {
            v.state = "failed";
            v.failure = Some(Failure {
                kind: "configuration",
                headline: "There is no update to install.".to_string(),
                detail: "install was called before a check found an update".to_string(),
            });
        });
    };

    transition(app, |v| {
        v.state = "downloading";
        v.downloaded_bytes = 0;
        v.total_bytes = None;
        v.percent = None;
        v.failure = None;
    });

    // Progress is emitted on a THROTTLE, not per chunk. reqwest hands back chunks in the
    // low tens of kilobytes, so the event count scales with the payload and the payload is
    // about to change by an order of magnitude (CEO decision 16 deletes `app/acp-adapter/`).
    // A time-based throttle is the only kind that is correct at both sizes: no byte count,
    // no chunk count, no threshold tuned to today's bundle.
    let app_for_chunks = app.clone();
    let mut received: u64 = 0;
    let mut last_emit = Instant::now() - Duration::from_millis(200);
    let on_chunk = move |chunk: usize, total: Option<u64>| {
        received += chunk as u64;
        let done = total.map(|t| received >= t).unwrap_or(false);
        if last_emit.elapsed() >= Duration::from_millis(100) || done {
            last_emit = Instant::now();
            let percent = total.and_then(|t| {
                if t == 0 {
                    None
                } else {
                    Some(((received.min(t) * 100) / t) as u8)
                }
            });
            transition(&app_for_chunks, |v| {
                v.state = "downloading";
                v.downloaded_bytes = received;
                v.total_bytes = total;
                v.percent = percent;
            });
        }
    };

    // The gap between the last byte and the first extracted file is where the signature is
    // checked, and it is long enough to look like a stall. So it gets its own state and its
    // own sentence in the UI rather than a bar frozen at 100%. Deliberately not tied to any
    // duration: minisign over the whole payload takes as long as the payload is long.
    let app_for_finish = app.clone();
    let on_finish = move || {
        transition(&app_for_finish, |v| {
            v.state = "installing";
            v.percent = Some(100);
        });
    };

    match update.download_and_install(on_chunk, on_finish).await {
        Ok(()) => transition(app, |v| {
            v.state = "ready";
            v.percent = Some(100);
        }),
        Err(e) => {
            let failure = Failure::classify(&e);
            transition(app, |v| {
                v.state = "failed";
                v.failure = Some(failure);
            })
        }
    }
}

// ---------------------------------------------------------------------------------------
// The work gate
// ---------------------------------------------------------------------------------------

/// How often the gate is re-read while an update is waiting. See [`spawn_work_watcher`].
const WATCH_INTERVAL: Duration = Duration::from_secs(5);

/// The two states in which the CEO has something to act on, and therefore the only two in
/// which the gate is worth reading at all. Everywhere else the watcher does a single mutex
/// read and goes back to sleep.
fn state_awaits_the_ceo(state: &str) -> bool {
    matches!(state, "available" | "ready")
}

/// Take the three readings, from the shell, without ever locking the spine for an answer.
///
/// The readings and the reasoning about each are in [`richos_core::work_gate`]'s module doc;
/// this function is only the part that has to touch handles. It is deliberately tiny and
/// deliberately dumb — every decision it could make is made there, where the spine suite can
/// test it.
fn work_verdict(app: &AppHandle) -> WorkVerdict {
    let Some(state) = app.try_state::<crate::AppState>() else {
        // Before `setup` has managed the state there is no app to be busy. Reachable only in
        // the window before the window exists, where nothing can have pressed anything.
        return work_gate::decide(&WorkSources::all_clear());
    };

    // 1. THE ACTIVE TURN — the spine's own mirror, read without the spine's mutex. Never
    //    inferred from silence (continuity §5.2).
    let turn =
        if state.control.active_turn().is_some() { Liveness::Busy } else { Liveness::Clear };

    // 2. WHETHER THE SPINE IS BEING DRIVEN AT ALL. `try_lock`, never `lock`: `send_message`
    //    holds this mutex for the entire length of a turn, so blocking here would answer
    //    after the turn it means to protect had ended. A lock we cannot take is UNKNOWN, and
    //    unknown waits — which is what covers the window at `spine.rs:1609` where the mirror
    //    is already cleared and `drain_queue` has not yet begun the next queued turn.
    let spine = match state.spine.try_lock() {
        Ok(_guard) => Liveness::Clear,
        Err(_) => Liveness::Unknown,
    };

    // 3. WORKERS — the "all work" half the composer cannot see. The session id comes from
    //    the same control, so this reads THIS session's directory and never the
    //    mtime-newest one on the machine (`worker_status`'s own first claim).
    let view =
        richos_core::worker_status::current_status(state.control.lease_session().as_deref());
    let (workers, worker_gap) = work_gate::workers(&view);

    work_gate::decide(&WorkSources { turn, spine, workers, worker_gap })
}

/// Re-read the gate and write it into the view. Emits only when something CHANGED.
///
/// The "only when changed" is not an optimization, it is the ruling: *"Nothing about the
/// update may interrupt. No modal, no focus steal, no repeated prompting while work runs."*
/// An event every five seconds that says the same thing is a surface that repaints under his
/// hands for no reason.
fn refresh_work_verdict(app: &AppHandle) -> WorkVerdict {
    let verdict = work_verdict(app);
    let changed = {
        let state = app.state::<Updates>();
        let guard = state.view.lock().expect("update view lock");
        guard.busy != verdict.busy
            || guard.busy_reason != verdict.reason
            || guard.unchecked != verdict.unchecked
    };
    if changed {
        let v = verdict.clone();
        transition(app, move |view| {
            view.busy = v.busy;
            view.busy_reason = v.reason;
            view.unchecked = v.unchecked;
        });
    }
    verdict
}

/// Watch the gate for as long as there is something the CEO could act on.
///
/// **WHY A POLL AND NOT AN EVENT.** The turn half could be pushed — the spine already emits
/// `TurnStatus` — but the worker half cannot: a worker's state changes through hook writes
/// in another process and produces no signal in this one, which is the same fact
/// `spine.rs`'s own "one last worker re-join" comment records. So workers must be read, and
/// once one source is read the other may as well be read beside it rather than growing two
/// mechanisms that agree most of the time.
///
/// **WHAT IT COSTS, MEASURED RATHER THAN ASSERTED.**
/// `crates/richos-core/tests/work_gate_cost.rs` times the whole question — the worker read
/// plus the decision — against a deliberately pessimistic fixture: 3,000 worker rows, half
/// of them open runs, so 1,500 liveness syscalls per read. On this machine, release profile,
/// 2026-09-05: **4,825 us per read**. The duty cycle is that over the interval:
///
/// ```text
/// 4_825 us / 5_000_000 us = 0.0965 % of one core
/// ```
///
/// and only while an update is waiting. In every other state the tick is a single mutex read
/// of a `&str` and returns, which is why the loop does that read FIRST. A real session's
/// file on the same machine held 2,918 rows with far fewer open runs, so the shipped cost is
/// below the measured one rather than above it.
///
/// **WHY 5 s AND NOT 1 s.** The only thing a shorter interval buys is that the cue reappears
/// sooner after work ends; it costs five times the reads to buy it, and 0.48 % of a core to
/// make chrome arrive four seconds earlier is the wrong trade for a ruling whose whole
/// content is *"not important enough to get in the way"*. **WHY NOT 30 s:** the cue would be
/// absent for up to half a minute after his work finished, which reads as an app that has
/// not noticed rather than one that is waiting.
pub fn spawn_work_watcher(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(WATCH_INTERVAL).await;
            let awaits = {
                let Some(updates) = app.try_state::<Updates>() else { continue };
                let guard = updates.view.lock().expect("update view lock");
                state_awaits_the_ceo(guard.state)
            };
            // Nothing is waiting on him, so there is no control to hide and nothing to say.
            // Deliberately NOT `break`: a check five minutes from now can put us back into
            // `available`, and a watcher that had exited would leave that update's cue
            // painted from whatever the verdict was when the check happened.
            if !awaits {
                continue;
            }
            refresh_work_verdict(&app);
        }
    });
}

// ---------------------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------------------

/// The view, with the work gate read FRESH rather than served from the last poll.
///
/// `updates.js` calls this when the settings menu is opened, which is the one moment the CEO
/// is deliberately looking at this surface. Serving him a verdict up to
/// `WATCH_INTERVAL` old there would be the one place a stale answer is guaranteed to be
/// seen — and it would be seen as an Install button that should not be there.
#[tauri::command]
pub fn update_state(app: AppHandle) -> UpdateView {
    refresh_work_verdict(&app);
    app.state::<Updates>().snapshot()
}

#[tauri::command]
pub async fn update_check(app: AppHandle) -> UpdateView {
    check(&app).await
}

#[tauri::command]
pub async fn update_install(app: AppHandle) -> UpdateView {
    install(&app).await
}

/// Restart into the version that was just put in place.
///
/// **THIS FUNCTION WAS `app.restart()` AND NOTHING ELSE — two lines, no condition — and that
/// was the worst of the three defects the CEO found on 2026-09-05.** `restart` replaces the
/// process, so pressing it mid-turn kills a live `claude` child mid-answer: the session
/// continuity design's first structural invariant (§3.1) broken by a button that looked
/// safe. The turn would be recorded afterwards as *Ended, outcome not recorded* — visible
/// after the fact and not preventable, and he would have caused it himself.
///
/// It now returns the view instead of never returning, because refusing is a real outcome
/// that the surface has to render. On the success path it still never returns.
#[tauri::command]
pub fn update_relaunch(app: AppHandle) -> UpdateView {
    let verdict = refresh_work_verdict(&app);
    if verdict.busy {
        // Still `ready` — the new bundle IS on disk and installed. Only the swap of the
        // running process is refused, which is exactly the dangerous half.
        return app.state::<Updates>().snapshot();
    }
    app.restart();
}

// ---------------------------------------------------------------------------------------
// The automatic check
// ---------------------------------------------------------------------------------------

/// Check once, shortly after launch, on a background task.
///
/// SILENT ONLY WHEN THERE IS NOTHING TO SAY. It emits `rich://update` for every transition
/// exactly as the button does, so the settings surface shows the result and the rail's gear
/// carries a mark when something was found — the CEO can always see that RichOS checked and
/// what it found. It does not download and it does not install.
///
/// The delay is not cosmetic: `setup` has just replayed the ledger and built the window, and
/// a TLS handshake competing with first paint is a slower first paint for a result nobody is
/// waiting on.
pub fn spawn_launch_check(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(Duration::from_secs(3)).await;
        let _ = check(&app).await;
    });
}

// ---------------------------------------------------------------------------------------
// The headless end-to-end mode
// ---------------------------------------------------------------------------------------

/// `RICHOS_UPDATE_SELFTEST=check|install`, read once at launch.
pub fn selftest_mode() -> Option<String> {
    match std::env::var(SELFTEST_ENV) {
        Ok(v) if v == "check" || v == "install" => Some(v),
        _ => None,
    }
}

/// Drive the real flow from the command line and exit with a meaningful code.
///
/// WHY THIS EXISTS RATHER THAN A SCRIPTED CLICK. Proving an update end to end means a
/// process that is a real `.app` bundle replacing itself — nothing outside a bundle can
/// exercise `install_inner`, which resolves the bundle from `current_exe`. Driving the GUI
/// with AppleScript would need an Accessibility grant that an ad-hoc bundle loses on every
/// rebuild, i.e. exactly the grant this repository has measured as dying. So the harness
/// calls the SAME `check` and `install` functions the two commands call — not a copy of
/// them, and not a reimplementation with the verification left out.
///
/// It prints one machine-readable line per transition, prefixed, so `updater-e2e.sh` asserts
/// on states rather than on log prose.
///
/// Exit codes: 0 the requested operation reached its terminal success state; 10 the check
/// found nothing; 11 it failed; 12 the install failed. The failure KIND is on stdout, which
/// is how case T asserts that a tampered artifact is refused for the signature and not for
/// something that merely resembles it.
pub fn spawn_selftest(app: AppHandle, mode: String) {
    tauri::async_runtime::spawn(async move {
        let say = |v: &UpdateView| {
            println!(
                "RICHOS-UPDATE-SELFTEST state={} current={} available={} percent={} failure={} detail={}",
                v.state,
                v.current_version,
                v.available_version.clone().unwrap_or_else(|| "-".into()),
                v.percent.map(|p| p.to_string()).unwrap_or_else(|| "-".into()),
                v.failure.as_ref().map(|f| f.kind).unwrap_or("-"),
                v.failure
                    .as_ref()
                    .map(|f| f.detail.replace('\n', " "))
                    .unwrap_or_else(|| "-".into()),
            );
            use std::io::Write;
            let _ = std::io::stdout().flush();
        };

        let checked = check(&app).await;
        say(&checked);

        let code = match checked.state {
            "available" if mode == "install" => {
                let installed = install(&app).await;
                say(&installed);
                if installed.state == "ready" {
                    0
                } else {
                    12
                }
            }
            "available" => 0,
            "upToDate" => 10,
            _ => 11,
        };
        println!("RICHOS-UPDATE-SELFTEST exit={code}");
        use std::io::Write;
        let _ = std::io::stdout().flush();
        std::process::exit(code);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The classifier is the only judgement this file makes about a vendor error, and the
    /// signature arm is the one that must never widen. A minisign failure that came back as
    /// "network" would be offered a Retry button, and a retry against a tampered artifact
    /// refuses again — turning a security refusal into something a person clicks through.
    #[test]
    fn a_minisign_failure_is_classified_as_a_signature_failure_and_nothing_else() {
        let err = tauri_plugin_updater::Error::SignatureUtf8("not base64".into());
        let f = Failure::classify(&err);
        assert_eq!(f.kind, "signature");
        assert!(f.headline.contains("not signed by RichOS"));
        // The vendor's own words survive into the payload.
        assert!(f.detail.contains("not base64"));
    }

    #[test]
    fn an_unreachable_server_is_offline_and_a_bad_manifest_is_not() {
        let manifest = tauri_plugin_updater::Error::ReleaseNotFound;
        assert_eq!(Failure::classify(&manifest).kind, "manifest");

        let target = tauri_plugin_updater::Error::TargetNotFound("darwin-aarch64".into());
        assert_eq!(Failure::classify(&target).kind, "manifest");

        let empty = tauri_plugin_updater::Error::EmptyEndpoints;
        assert_eq!(Failure::classify(&empty).kind, "configuration");

        let insecure = tauri_plugin_updater::Error::InsecureTransportProtocol;
        assert_eq!(Failure::classify(&insecure).kind, "configuration");
    }

    /// A fresh view on a placeholder endpoint must not read as "up to date" or as an error.
    /// "No update server has been chosen yet" is a THIRD thing, and the UI needs it to be.
    #[test]
    fn the_committed_placeholder_endpoint_opens_as_unconfigured() {
        let v = UpdateView::new(
            "0.1.0".into(),
            format!("https://{PLACEHOLDER_ENDPOINT_HOST}/x"),
            true,
        );
        assert_eq!(v.state, "unconfigured");
        assert!(v.endpoint_is_placeholder);
        assert!(v.failure.is_none());
    }

    #[test]
    fn a_real_endpoint_opens_as_idle_with_nothing_claimed_about_it() {
        let v = UpdateView::new("0.1.0".into(), "https://example.com/u".into(), false);
        assert_eq!(v.state, "idle");
        assert!(!v.endpoint_is_placeholder);
        assert!(v.checked_at.is_none(), "never checked is not the same as checked and clean");
        assert!(v.available_version.is_none());
    }
}
