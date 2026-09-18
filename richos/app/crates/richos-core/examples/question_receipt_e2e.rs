//! **"I'll check." / "I'll investigate." — one real turn of each kind, against a real
//! provider.** The CEO's ruling §58, 2026-09-18.
//!
//! *"when the user asks Rich a question (in RichOS app) and the front desk Rich doesn't
//! immediately know the answer and therefore has to get it from the back-end Rich, the front
//! desk Rich should reply as follows: If the answer from the back-end Rich is expected to take
//! more than a minute, then the front desk Rich should reply with "I'll investigate." … And if
//! the answer from the back-end Rich is expected to take less than a minute, then the front
//! desk Rich should reply with "I'll check.""*
//!
//! Every other check on this feature drives the app's own code with the model's decision
//! supplied. This one asks a real front-desk lease a real question and reads what it says. It
//! is the only thing that can fail for the one reason the others cannot: the doctrine and the
//! tool description not actually reaching the model.
//!
//! ## What it measures, and what the number does NOT contain
//!
//! **Send → his first words**, taken off `LiveEvent::MessageStarted` / `MessageDelta` — the
//! events the webview renders Rich's text from, so this is the instant the sentence appears
//! rather than the instant the turn ends. §55's acceptance criterion is *"the time from send to
//! "On it!" on screen is the model's first words, a few seconds; 35 s is a defect"*, and §58's
//! two sentences inherit it.
//!
//! | Component | In this number? |
//! |---|---|
//! | The model's own latency before it says anything | **Yes** — and it is the whole of it |
//! | Every tool call it makes before speaking | **Yes.** That is the term §55 exists to remove |
//! | Writing the assignment down, fsynced | **Yes** (measured separately at ~1 ms by `assignment_receipt_timing`) |
//! | Spawning the work lease, preparing a workspace, the answer itself | **No.** All of it is after the turn |
//! | WebKit laying the text out | **No.** This is the event the webview renders from, not a paint |
//!
//! **What this probe does NOT do, said here rather than discovered later: it does not put the
//! app on screen.** There is no window, so it cannot say what the TIMER beside the reply reads
//! — that is `ui/tests/question-timer.js`, under WebKit, against the shipping renderer. Nor
//! does it wait for the answer to come back: the back-end lease that answers a question is the
//! work host's, which this probe does not start. Both are named in the record this writes.
//!
//! ## What it costs and what it touches
//!
//! **TWO MODEL TURNS on the CEO's subscription**, one question of each kind, and it is opt-in
//! for exactly that reason. Everything it writes goes into a throwaway directory under the
//! system temp directory, which it removes; `HOME` is left alone, because the provider
//! credentials live there and a synthetic one would make this probe measure a sign-in failure.
//! No audio device is opened and nothing is played.
//!
//! Run:
//! ```text
//! cargo run -p richos-core --example question_receipt_e2e -- <engine> <delivered-runtime>
//! ```

use richos_core::live::LiveEvent;
use richos_core::{ecs::EcsBridge, native::{resolve_claude_bin, NativeCognition}};
use richos_core::{EntityId, EntityRegistry, Ledger, Source, Spine};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// Removed on the way out unless `RICHOS_PROBE_KEEP_FIXTURE` is set — the same contract every
/// other real-provider example in this directory keeps, and the CEO's §54: a scratch location
/// is cleaned up however its maker ends.
struct Scratch(PathBuf);
impl Drop for Scratch {
    fn drop(&mut self) {
        if std::env::var_os("RICHOS_PROBE_KEEP_FIXTURE").is_some() {
            eprintln!("Retained fixture: {}", self.0.display());
        } else {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

/// The first instant Rich's own text reached the surface, and nothing else.
///
/// **Only the first**, because that is the measure: a later delta is more of the same sentence.
/// `MessageStarted` can arrive with no text at all, so both it and the first `MessageDelta`
/// count — whichever the wire produced first.
#[derive(Default)]
struct FirstWords {
    at: Mutex<Option<Instant>>,
}
impl richos_core::live::LiveObserver for FirstWords {
    fn on_live_event(&self, event: &LiveEvent) {
        let is_text = matches!(event, LiveEvent::MessageStarted { .. } | LiveEvent::MessageDelta { .. });
        if !is_text {
            return;
        }
        let mut at = self.at.lock().unwrap();
        if at.is_none() {
            *at = Some(Instant::now());
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    // **The app-owned MCP servers are served by THIS executable**, because `mcp_config` points
    // the child at `current_exe()` (`native.rs`). In the app that is `richos-tauri`; here it is
    // this example, so it has to answer the same three flags or the front desk comes up without
    // the register — and a probe whose front desk has no register would report a model failure
    // that is really a wiring failure.
    if args.len() == 2 {
        let scope = PathBuf::from(&args[1]);
        match args[0].to_string_lossy().as_ref() {
            "--onboarding-mcp" => {
                richos_core::onboarding_tools::run_stdio(&scope)?;
                return Ok(());
            }
            "--assignments-mcp" => {
                richos_core::assignment_tools::run_stdio(&scope)?;
                return Ok(());
            }
            "--status-mcp" => {
                // **`UnknownScreen`, not the Mac's.** The real screen source is in the Tauri
                // shell (`src-tauri/src/screen.rs`), and this probe asks nothing about the
                // screen: §56's reading is honestly "not established" here rather than
                // borrowed from a second implementation that might not agree with it.
                richos_core::status_tools::run_stdio(&scope, &richos_core::screen::UnknownScreen)?;
                return Ok(());
            }
            _ => {}
        }
    }
    if args.len() != 2 {
        return Err("usage: question_receipt_e2e ENGINE DELIVERED_RUNTIME".into());
    }
    let engine = std::fs::canonicalize(&args[0])?;
    let root = Scratch(std::env::temp_dir().join(format!("richos question {}", uuid::Uuid::new_v4())));
    let data = root.0.join("app data");
    std::fs::create_dir_all(data.join("corpus/ceo/records"))?;

    let runtime = richos_core::runtime::EngineRuntime::load(&engine, Some(&PathBuf::from(&args[1])))?;
    let mut profile = richos_core::engine_profile::EngineProfile::prepare(&engine, &data, runtime.clone())?;
    let mut registry = EntityRegistry::from_existing_ids(&[EntityId::parse("depot")?]);
    // One synthetic repository, so a question that mentions a project has somewhere real to be
    // about. Nothing in this probe asks the back end to touch it.
    let repo = root.0.join("first project");
    std::fs::create_dir(&repo)?;
    registry =
        richos_core::repositories::connect(&registry, &EntityId::parse("depot")?, &repo, true, &runtime, &[&engine, &data])?.0;
    registry.save(&data.join("entities.json"))?;

    let doctrine = richos_core::doctrine::ensure_rendered(&data, &Default::default())?;
    let skills = richos_core::skills::ensure_rendered(&data)?;
    let bridge = EcsBridge::new(&runtime.python, &engine, &data.join("ecs"))?;

    let mut spine = Spine::new(Ledger::open(&data.join("ledger.jsonl"))?);
    spine.set_entity_registry(registry);
    spine.set_machinery_journal(richos_core::journal::MachineryJournal::new(data.join("machinery")));
    let first_words = Arc::new(FirstWords::default());
    struct Forward(Arc<FirstWords>);
    impl richos_core::live::LiveObserver for Forward {
        fn on_live_event(&self, event: &LiveEvent) {
            self.0.on_live_event(event);
        }
    }
    spine.set_live_observer(Box::new(Forward(first_words.clone())));

    let thread = spine.create_thread("Question probe", &EntityId::parse("depot")?)?;
    profile.scope_to(&spine.ledger().thread_binding(&thread)?)?;
    let state_root = profile.state.clone();
    let cognition = NativeCognition::start_with_engine(
        &resolve_claude_bin(),
        &doctrine,
        &skills,
        &std::env::current_exe()?,
        bridge.clone(),
        profile,
        None,
    )?;
    spine.set_central_root(data.join("corpus"));
    spine.set_onboarding_record(data.join("onboarding.json"));
    spine.attach_lease(Box::new(cognition));

    // The two questions. Neither is answerable from the conversation itself, and neither is a
    // question about how work is going — which is the one class the doctrine answers from the
    // status read instead.
    //
    // They are phrased the way he would phrase them, because the whole thing under test is
    // whether the model reads them as questions at all.
    let questions = [
        (
            "check",
            "Did that pricing review ever actually land, or is it still sitting on a branch somewhere?",
        ),
        (
            "investigate",
            "Why has the nightly build been failing since Tuesday? I want to know what's actually causing it.",
        ),
    ];

    let mut rows = Vec::new();
    for (expected_kind, question) in questions {
        *first_words.at.lock().unwrap() = None;
        let sent = Instant::now();
        let turn = spine.submit_prompt(question, Source::Text)?;
        let turn_ended = sent.elapsed();
        let to_first_words = first_words.at.lock().unwrap().map(|at| at.duration_since(sent));
        let said = spine.ledger().turn(&turn).unwrap().assistant_text.trim().to_string();
        rows.push((expected_kind, question, said.clone(), to_first_words, turn_ended));

        eprintln!("---");
        eprintln!("asked      : {question}");
        eprintln!("he said    : {said:?}");
        match to_first_words {
            Some(d) => eprintln!("send -> first words : {:.3} s", d.as_secs_f64()),
            None => eprintln!("send -> first words : NOT OBSERVED (no live text event)"),
        }
        eprintln!("send -> turn ended  : {:.3} s", turn_ended.as_secs_f64());
    }

    // What the register actually holds. The kind on disk is what the timer and the status read
    // use, so a right sentence over a wrong record would be half the feature.
    let recorded = richos_core::assignment::read_all(&state_root, "depot", &thread)?;
    eprintln!("---");
    eprintln!("assignments written: {}", recorded.len());
    for row in &recorded {
        eprintln!("  kind={} state={} title={:?}", row.kind.as_str(), row.state.as_str(), row.title);
    }

    // ---- the assertions, each one a way §58 could be live and still wrong ----------------
    let mut failures = Vec::new();
    for (expected_kind, question, said, to_first_words, _) in &rows {
        let expected_sentence = if *expected_kind == "check" { "I'll check." } else { "I'll investigate." };
        // The sentence, whole. Either of the two is accepted for either question — the estimate
        // is his rough guess and a probe that failed on it would be grading the model's judgment
        // rather than the feature. What is NOT accepted is anything else at all.
        if said != "I'll check." && said != "I'll investigate." {
            failures.push(format!("the reply was neither sentence: {said:?} (asked: {question})"));
        }
        if said != expected_sentence {
            eprintln!(
                "NOTE: expected {expected_sentence:?} for this question and got {said:?}. Not a failure — \
                 the estimate is the model's rough guess (§58: \"just a rough estimate\"). Recorded so a \
                 drift in judgment is visible."
            );
        }
        // §55's acceptance criterion, inherited.
        match to_first_words {
            None => failures.push("no live text event was observed, so nothing was measured".into()),
            Some(d) if d.as_secs_f64() > 35.0 => {
                failures.push(format!("send -> first words was {:.3} s; 35 s is a defect (§55)", d.as_secs_f64()))
            }
            Some(_) => {}
        }
    }
    if recorded.len() != rows.len() {
        failures.push(format!("{} assignments written for {} questions", recorded.len(), rows.len()));
    }
    for row in &recorded {
        if !row.kind.is_question() {
            failures.push(format!("a question was written down as a task: {:?}", row.title));
        }
    }

    if !failures.is_empty() {
        for why in &failures {
            eprintln!("FAIL: {why}");
        }
        return Err(format!("{} check(s) failed", failures.len()).into());
    }
    eprintln!("---");
    eprintln!("PASS: both questions answered with one of §58's two sentences, both written down as questions.");
    Ok(())
}
