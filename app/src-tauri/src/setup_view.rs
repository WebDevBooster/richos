//! FIRST RUN, THE SURFACE — one consent step, then progress, then done.
//!
//! `richos_core::setup` decides and does; this file is what the window talks to. It holds no
//! decisions of its own, for the reason `memory.rs` holds none: two places that both know
//! where an engine may live is how an install succeeds and a boot then fails to find it.
//!
//! # What the CEO sees, and what he is spared
//!
//! **No terminal. No path. No version number.** One sheet naming what is about to be
//! installed and why, a button, progress while it runs, and a sentence at the end. The
//! consent copy is [`richos_core::setup::Component::why`], and a test asserts it carries no
//! slash, no dollar sign, no digit and no mention of Terminal.
//!
//! **And it does not imply zero-touch.** RichOS is BYO-Anthropic: `open-items.md` row 3.14
//! lists it as the second of the three things to settle — *"D removes one setup step of two,
//! not all of them — RichOS is BYO-Anthropic, so the customer still needs an account and a
//! login, and D must not be sold to him as zero-touch."* [`SETUP_ACCOUNT_NOTE`] is that
//! sentence in his language, on the same sheet, before he presses anything.
//!
//! # Progress, and why it is an event rather than a return value
//!
//! Anthropic's installer downloads the `claude` binary — 197,220,928 B on a Mac with no
//! `zstd`, which macOS 15.6 does not ship (§19, finding 3). A command that returns only when
//! that finishes is a window that looks hung for minutes. Each step emits [`EVENT_SETUP`] as
//! it starts and as it ends, so the surface can say what is happening while it happens.
//!
//! # The failure contract
//!
//! Every failure is a named `SetupError`, its `Display` is written for the CEO, and the
//! `finished` event carries `machine_unchanged` so the surface can say whether anything on his
//! Mac was touched. **A step that fails stops the run**: installing an engine for a Claude that
//! is not there produces a half-set-up machine that reports two successes and works for
//! nothing, which is the failure mode this whole module exists to avoid.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use richos_core::setup::{
    self, BashRunner, Component, CurlFetcher, SetupError, SetupPaths, SetupStatus, TarExtractor,
};
use serde::Serialize;
use tauri::{AppHandle, Emitter};

/// The channel the window listens on while setup runs.
pub const EVENT_SETUP: &str = "richos://setup";

/// **The sentence that keeps this honest.** He still needs his own Anthropic account and a
/// completed login; there is no login flow inside RichOS (§19). Shown on the consent sheet,
/// before the button, not in a footnote afterwards.
pub const SETUP_ACCOUNT_NOTE: &str =
    "You'll still need your own Anthropic account, and to sign in to it once. \
     I can't do that part for you, and I never see your password.";

/// The sentence a build with no engine pin shows INSTEAD of a button.
///
/// It exists as a `const` rather than only as `SetupError::EngineUnpinned`'s `Display`
/// because `affordances.js` scrapes the product's CEO-facing sentences out of the source and
/// classifies every one of them, and a `#[error(...)]` attribute is not a place it can see.
/// A sentence the state registry cannot see is a sentence nobody has said whether the CEO can
/// act on. The test below requires the two to be the same string, so there is one wording and
/// not two.
pub const SETUP_UNPINNED_NOTE: &str =
    "This copy of RichOS wasn't built with an engine to install, so I can't fetch one. \
     It needs whoever set RichOS up to publish one and pin it.";

/// One step of the run, as it happens.
#[derive(Debug, Clone, Serialize)]
pub struct SetupProgress {
    /// `started`, `done`, `failed`, or `finished` for the whole run.
    pub state: &'static str,
    /// Which component this is about, when it is about one.
    pub component: Option<&'static str>,
    /// What the CEO reads for this line — his language, no path.
    pub what: String,
    /// 1-based position, and how many steps in total.
    pub index: usize,
    pub total: usize,
    /// The failure's own sentence, when `state` is `failed`.
    pub detail: Option<String>,
    /// The machine tag, for the operator's log and the tests. Never rendered.
    pub kind: Option<&'static str>,
    /// Whether his Mac is unchanged. Only meaningful with `state == "failed"`.
    pub machine_unchanged: Option<bool>,
}

fn emit(app: &AppHandle, p: SetupProgress) {
    // The operator's line first, so a run is legible in a log with no window attached.
    match (p.state, &p.detail) {
        ("failed", Some(d)) => eprintln!("[richos] setup {}/{} FAILED — {d}", p.index, p.total),
        (state, _) => eprintln!("[richos] setup {}/{} {state}: {}", p.index, p.total, p.what),
    }
    let _ = app.emit(EVENT_SETUP, p);
}

/// Read this machine, using the SAME engine answer the boot used.
///
/// `boot_engine` is `main.rs::resolve_engine`'s result when it found a real one. Passing it in
/// rather than re-deriving it is the whole point: the repo-ancestor candidates (`engine.rs` 4
/// and 5) are a dogfood layout that `setup.rs` deliberately does not reimplement, and a
/// developer running from the checkout must never be asked to install something already three
/// directories away.
pub fn detect(boot_engine: Option<&std::path::Path>) -> SetupStatus {
    let extra: Vec<PathBuf> = boot_engine
        .filter(|d| setup::engine_looks_valid(d))
        .map(|d| vec![d.to_path_buf()])
        .unwrap_or_default();
    setup::detect(&SetupPaths::from_process(), &extra)
}

/// What the consent sheet says, assembled from the status. Returned to the window so the copy
/// lives in one place and the window renders rather than composes.
#[derive(Debug, Clone, Serialize)]
pub struct SetupAsk {
    /// One line per missing component: what it is, and what it is for.
    pub items: Vec<SetupAskItem>,
    /// [`SETUP_ACCOUNT_NOTE`].
    pub account_note: &'static str,
    /// `true` when everything missing can actually be installed by this build. `false` puts
    /// the sheet in its explain-rather-than-offer state.
    pub can_install: bool,
    /// Why not, when `can_install` is false — the CEO-facing sentence, not a code.
    pub cannot_install_reason: Option<String>,
}

/// One row of the consent sheet.
#[derive(Debug, Clone, Serialize)]
pub struct SetupAskItem {
    pub component: &'static str,
    pub name: &'static str,
    pub why: &'static str,
}

/// **The one shape both commands return**, so the window never has to know which command it
/// came from. `complete` is here rather than on `SetupStatus` because it is a derived answer
/// (`SetupStatus::needs().is_empty()`), and a serialized field that duplicates a method is a
/// second place for the answer to be wrong.
pub fn view(status: &SetupStatus) -> serde_json::Value {
    serde_json::json!({
        "status": status,
        "ask": ask_for(status),
        "complete": status.complete(),
    })
}

/// Turn a status into the sheet's contents.
pub fn ask_for(status: &SetupStatus) -> SetupAsk {
    let needs = status.needs();
    let items = needs
        .iter()
        .map(|c| SetupAskItem { component: c.as_str(), name: c.display_name(), why: c.why() })
        .collect();
    let blocked = status.blocked();
    SetupAsk {
        items,
        account_note: SETUP_ACCOUNT_NOTE,
        can_install: !needs.is_empty() && !blocked,
        cannot_install_reason: blocked.then(|| SETUP_UNPINNED_NOTE.to_string()),
    }
}

/// **HE PRESSES THE BUTTON.** Install everything missing, in order, reporting each step.
///
/// `engine_dir` is the shared cell the lease factory reads (`main.rs::EngineLeaseFactory`).
/// A successful engine install rewrites it, so the next lease — a rotation, a recovery, or the
/// attach this function attempts — starts `claude` in the engine that was just installed,
/// **without a relaunch**. That property is not a nicety: `provision_memory` already set it as
/// the standard, after a customer's first five minutes were spent with a corpus he had just
/// created and a desk that would not open until he quit.
pub fn run(
    app: &AppHandle,
    boot_engine: Option<&std::path::Path>,
    engine_dir: &Arc<Mutex<PathBuf>>,
) -> Result<SetupStatus, String> {
    let status = detect(boot_engine);
    let needs = status.needs();
    if needs.is_empty() {
        // Nothing to do is a success with no steps, not an error and not a no-op that looks
        // like one: the window asked because the status said to, and the status can have
        // changed under it (he installed Claude Code himself in another window).
        let mut done = status;
        done.installed_now = true;
        return Ok(done);
    }
    let total = needs.len();
    let paths = SetupPaths::from_process();

    for (i, component) in needs.iter().enumerate() {
        let index = i + 1;
        emit(
            app,
            SetupProgress {
                state: "started",
                component: Some(component.as_str()),
                what: started_line(*component),
                index,
                total,
                detail: None,
                kind: None,
                machine_unchanged: None,
            },
        );

        let outcome: Result<String, SetupError> = match component {
            Component::ClaudeCode => setup::install_claude_code(&CurlFetcher, &BashRunner, &paths)
                .map(|r| {
                    // The operator's line names the binary and its signature verdict, and
                    // NOTHING about the account. RichOS may never collect, store or
                    // intermediate Claude credentials, and a log line is storage.
                    eprintln!(
                        "[richos] setup: Claude Code at {} — signature {} ({})",
                        r.installed_at,
                        if r.signature.trusted { "VERIFIED" } else { "REJECTED" },
                        r.signature.checked
                    );
                    format!("Claude Code is installed. ({} bytes of installer)", r.installer_bytes)
                }),
            Component::Engine => match setup::engine_pin() {
                None => Err(SetupError::EngineUnpinned),
                Some(pin) => {
                    let home = match paths.home.as_deref() {
                        Some(h) => h.to_path_buf(),
                        None => {
                            let e = SetupError::NoHome;
                            emit_failure(app, *component, index, total, &e);
                            return Err(e.to_string());
                        }
                    };
                    let dest = setup::engine_install_dir(&home);
                    setup::install_engine(&CurlFetcher, &TarExtractor, &pin, &dest).map(|r| {
                        eprintln!(
                            "[richos] setup: engine {} at {} — sha256 {}, {} bytes",
                            r.version, r.installed_at, r.sha256, r.bytes
                        );
                        // THE LEASE FACTORY NOW POINTS AT IT. Without this line the app would
                        // have an engine on disk and keep starting `claude` in the directory
                        // it failed to find at boot.
                        if let Ok(mut cell) = engine_dir.lock() {
                            *cell = dest.clone();
                        }
                        "Your engine is installed.".to_string()
                    })
                }
            },
        };

        match outcome {
            Ok(what) => emit(
                app,
                SetupProgress {
                    state: "done",
                    component: Some(component.as_str()),
                    what,
                    index,
                    total,
                    detail: None,
                    kind: None,
                    machine_unchanged: None,
                },
            ),
            Err(e) => {
                emit_failure(app, *component, index, total, &e);
                // STOP. A half-set-up machine that reports two successes and works for
                // nothing is exactly what this module exists to prevent.
                return Err(e.to_string());
            }
        }
    }

    // RE-READ FROM DISK. Not "every step returned Ok, therefore it is all there" — the same
    // rule `install_claude_code` applies to Anthropic's own exit code.
    let mut after = detect(boot_engine);
    after.installed_now = true;
    emit(
        app,
        SetupProgress {
            state: "finished",
            component: None,
            what: if after.complete() {
                "That's everything. I'm ready.".to_string()
            } else {
                // Reached only if something removed a component between the install and this
                // line. It is still not reported as a success.
                "Something is still missing.".to_string()
            },
            index: total,
            total,
            detail: None,
            kind: None,
            machine_unchanged: Some(true),
        },
    );
    Ok(after)
}

fn emit_failure(
    app: &AppHandle,
    component: Component,
    index: usize,
    total: usize,
    e: &SetupError,
) {
    emit(
        app,
        SetupProgress {
            state: "failed",
            component: Some(component.as_str()),
            what: format!("{} could not be installed.", component.display_name()),
            index,
            total,
            detail: Some(e.to_string()),
            kind: Some(e.kind()),
            machine_unchanged: Some(e.machine_unchanged()),
        },
    );
}

/// The progress line, in his language. Present tense, no path, no byte count — the byte count
/// belongs on the operator's line, where it is useful.
fn started_line(c: Component) -> String {
    match c {
        Component::ClaudeCode => {
            "Getting Claude Code from Anthropic. This is the big one — a few minutes."
                .to_string()
        }
        Component::Engine => "Getting my instructions.".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// **THE CONSENT SHEET IS ONE STEP AND CARRIES THE ACCOUNT SENTENCE.** The BYO-Anthropic
    /// caveat is row 3.14's second condition and it must reach him before he presses anything,
    /// not after.
    #[test]
    fn the_consent_sheet_says_he_still_needs_his_own_account() {
        assert!(SETUP_ACCOUNT_NOTE.contains("Anthropic account"));
        assert!(SETUP_ACCOUNT_NOTE.contains("sign in"));
        assert!(SETUP_ACCOUNT_NOTE.contains("never see your password"));
        // No path, no digit, no terminal — the same floor the component copy meets.
        assert!(!SETUP_ACCOUNT_NOTE.contains('/'));
        assert!(!SETUP_ACCOUNT_NOTE.chars().any(|c| c.is_ascii_digit()));
    }

    /// **ONE WORDING, NOT TWO.** The const the state registry can see and the error the
    /// backend raises must be the same sentence, or the classified copy and the shipped copy
    /// drift and nobody finds out.
    #[test]
    fn the_unpinned_sentence_is_the_error_it_stands_for() {
        assert_eq!(SETUP_UNPINNED_NOTE, SetupError::EngineUnpinned.to_string());
        // And it names a party from `affordances.js`'s closed set, so a state he cannot fix
        // never leaves him with a fault and no owner.
        assert!(SETUP_UNPINNED_NOTE.contains("whoever set RichOS up"));
    }

    /// A progress line never puts a path or a version in front of him.
    #[test]
    fn no_progress_line_carries_a_path_or_a_version() {
        for c in [Component::ClaudeCode, Component::Engine] {
            let line = started_line(c);
            assert!(!line.contains('/'), "{line}");
            assert!(!line.contains('~'), "{line}");
            assert!(!line.chars().any(|ch| ch.is_ascii_digit()), "{line}");
        }
    }
}
