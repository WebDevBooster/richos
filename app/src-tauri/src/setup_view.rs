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

/// **What the CEO is told when he tries to send and the setting up was never done.**
///
/// THE DEFECT THIS CLOSES (ray-opus-a2, published v1.0.1, 2026-09-04). Four sends, four
/// refusals, no restart in between, and every one of them said: *"Quit RichOS and open it
/// again — that clears it most of the time."* On that machine
/// `~/Library/Application Support/RichOS/engine` held zero files, so quitting and reopening
/// was advice that could not work: the boot would look for an engine that was still not
/// there, fail to attach exactly as before, and hand him the same sentence. He would have
/// done it, watched it not work, and concluded the product was broken — which, in that
/// state, it was.
///
/// [`crate::LEASE_UNAVAILABLE_MESSAGE`] is not wrong; it is written for the OTHER no-lease
/// cause, the one where everything is installed and the account is not signed in. Quitting
/// and reopening genuinely does clear that one. The two causes were sharing a sentence, and
/// the sentence was true of only one of them.
///
/// So this is the arm where the cause is on disk in front of us. It says which piece is
/// missing, in the same words the consent sheet uses ([`Component::display_name`]), it
/// offers the one thing that fixes it — the sheet is reopened behind this notice, and
/// `run_setup` attaches a lease with no relaunch — and it closes the door on the advice that
/// cannot help: *there's nothing to quit and nothing to reopen*.
///
/// THREE ARMS AND THREE WHOLE SENTENCES, not one template with a hole in it. `affordances.js`
/// scrapes CEO-facing literals out of this source and classifies every one; a `{}` is a
/// sentence nobody can classify, and the state registry would be carrying a fragment instead
/// of the thing he reads.
pub const SETUP_INCOMPLETE_ENGINE: &str =
    "I can't take that on yet — the RichOS engine isn't on this Mac, and that's the part \
     of me that knows how I work. I've put the setting up back on your screen: press Set \
     it up and I'll fetch it. There's nothing to quit and nothing to reopen.";

/// The same state, when what is missing is the program rather than the instructions.
pub const SETUP_INCOMPLETE_CLAUDE: &str =
    "I can't take that on yet — Claude Code isn't on this Mac, and that's the program I \
     think with. I've put the setting up back on your screen: press Set it up and I'll \
     fetch it. There's nothing to quit and nothing to reopen.";

/// The same state on a Mac that has neither — the customer's, on the day he installs.
pub const SETUP_INCOMPLETE_BOTH: &str =
    "I can't take that on yet — this Mac doesn't have Claude Code or the RichOS engine, \
     and those are what I think with. I've put the setting up back on your screen: press \
     Set it up and I'll fetch them. There's nothing to quit and nothing to reopen.";

/// Which sentence he is shown, from what the DISK says — not from what a boot once thought.
///
/// An empty `needs` has no sentence here BY CONSTRUCTION: nothing is missing, so the no-lease
/// cause is the other one and [`crate::LEASE_UNAVAILABLE_MESSAGE`] is the honest answer. The
/// `Option` is what makes that a decision the caller has to make rather than a fallthrough.
///
/// A BLOCKED BUILD GETS THE SENTENCE THAT IS TRUE OF IT. Three of these four arms promise
/// "press Set it up", and on a build with no engine pin there is no such button to press —
/// `ask_for` hides it and shows [`SETUP_UNPINNED_NOTE`] instead. Promising a control that is
/// not drawn is the same class of defect as promising a restart that cannot work, so that
/// arm gets the note the sheet itself is showing, which names the party who can act.
pub fn incomplete_message(status: &SetupStatus) -> Option<&'static str> {
    let needs = status.needs();
    if needs.is_empty() {
        return None;
    }
    if status.blocked() {
        return Some(SETUP_UNPINNED_NOTE);
    }
    match (
        needs.contains(&Component::ClaudeCode),
        needs.contains(&Component::Engine),
    ) {
        (true, true) => Some(SETUP_INCOMPLETE_BOTH),
        (true, false) => Some(SETUP_INCOMPLETE_CLAUDE),
        (false, true) => Some(SETUP_INCOMPLETE_ENGINE),
        (false, false) => None,
    }
}

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

    /// A status shaped by hand, so each arm of [`incomplete_message`] can be asked for
    /// directly rather than depending on what this machine happens to have installed.
    fn status(claude: bool, engine: bool, installable: bool) -> SetupStatus {
        let mut st = detect(None);
        st.claude.present = claude;
        st.engine.present = engine;
        st.engine_installable = installable;
        st
    }

    /// **THE SENTENCE NEVER TELLS HIM TO QUIT AND REOPEN WHEN THAT CANNOT HELP.**
    ///
    /// ray-opus-a2, published v1.0.1, 2026-09-04: an engine directory holding zero files, and
    /// four sends refused with "Quit RichOS and open it again". The next boot would look for
    /// the same absent engine and fail the same attach, so the only instruction he was given
    /// was one that could not work.
    #[test]
    fn a_machine_missing_something_is_never_told_to_restart() {
        for (c, e) in [(true, false), (false, true), (false, false)] {
            let msg = incomplete_message(&status(c, e, true)).expect("something is missing");
            // The INSTRUCTION, not the word. These sentences end by ruling a restart out —
            // "there's nothing to quit and nothing to reopen" — so a bare search for "quit"
            // would flag the fix as the defect.
            assert!(
                !msg.contains("Quit RichOS"),
                "a state a restart cannot clear must not ask for one: {msg}"
            );
            assert!(
                !msg.contains("open it again"),
                "a state a restart cannot clear must not ask for one: {msg}"
            );
            // And it says so out loud, because he has already been told the opposite.
            assert!(
                msg.contains("nothing to quit and nothing to reopen"),
                "the sentence must close the door on the advice that cannot work: {msg}"
            );
        }
        // The sentence LEASE_UNAVAILABLE_MESSAGE carries is the one this arm must not
        // duplicate, and the two must stay different strings.
        assert_ne!(
            incomplete_message(&status(true, false, true)),
            Some(crate::LEASE_UNAVAILABLE_MESSAGE)
        );
    }

    /// **IT NAMES THE MISSING PIECE, AND OFFERS THE THING THAT FIXES IT.** Naming is the
    /// difference between a status and a diagnosis; the offer is the difference between a
    /// diagnosis and a way out.
    #[test]
    fn it_names_what_is_missing_and_offers_the_setting_up() {
        let engine = incomplete_message(&status(true, false, true)).unwrap();
        assert!(engine.contains("the RichOS engine"), "{engine}");
        let claude = incomplete_message(&status(false, true, true)).unwrap();
        assert!(claude.contains("Claude Code"), "{claude}");
        let both = incomplete_message(&status(false, false, true)).unwrap();
        assert!(both.contains("Claude Code") && both.contains("the RichOS engine"), "{both}");
        for msg in [engine, claude, both] {
            assert!(msg.contains("Set it up"), "the offer is missing: {msg}");
            // The same floor the rest of this surface meets.
            assert!(!msg.contains('/'), "{msg}");
            assert!(!msg.chars().any(|c| c.is_ascii_digit()), "{msg}");
        }
    }

    /// **A COMPLETE MACHINE FALLS THROUGH TO THE OTHER SENTENCE.** No lease with nothing
    /// missing is the signed-out case, and for that one quitting and reopening genuinely does
    /// clear it — which is why the two states must not share a sentence in either direction.
    #[test]
    fn a_complete_machine_has_no_setup_sentence() {
        assert!(incomplete_message(&status(true, true, true)).is_none());
    }

    /// **A BUILD THAT CANNOT INSTALL DOES NOT PROMISE A BUTTON.** `ask_for` hides "Set it up"
    /// when the engine is unpinned, so a sentence saying to press it would name a control the
    /// sheet is not drawing.
    #[test]
    fn a_blocked_build_says_what_the_sheet_says() {
        let msg = incomplete_message(&status(true, false, false)).unwrap();
        assert_eq!(msg, SETUP_UNPINNED_NOTE);
        assert!(!msg.contains("Set it up"), "{msg}");
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
