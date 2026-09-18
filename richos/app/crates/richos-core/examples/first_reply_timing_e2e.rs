//! **The register is the first tool call, and his first words are a few seconds away — measured
//! on a real provider, one task turn and one question turn.** The CEO's ruling §55, 2026-09-18:
//! *"Rich **immediately** replies with: "On it!" and only after that does all that work."* …
//! *"Yes, a few seconds is fine. But 35 seconds of waiting for the first response is not. Go."*
//!
//! # What this measures and what it refuses
//!
//! **Send → his first words**, taken off `LiveEvent::MessageStarted`/`MessageDelta` — the events
//! the webview renders Rich's text from, so this is when the sentence appears rather than when
//! the turn ends. And the TOOL CALLS on his turn ahead of that first word, which is the term §55
//! exists to remove. The rule the run is scored against is
//! [`richos_core::first_reply::first_reply_faults`], unit-tested against the real defect's own
//! frame sequence so it is proven able to go red.
//!
//! This is the after-measurement for `docs/verification/question-receipt-2026-09-18.md`, which
//! measured the same path at 12.197 s, 19.343 s, 22.956 s and 31.023 s to his first words, with
//! two `ToolSearch` round trips and a continuity checkpoint ahead of the register.
//!
//! # What it costs and what it touches
//!
//! **THREE MODEL TURNS on the CEO's subscription** — the lease's PRIMING turn, then one task and
//! one question — and it is opt-in for exactly that reason. The priming turn is counted here
//! because it always ran: before 2026-09-18 it ran inside the first `submit_prompt` and the probe
//! measured it as part of turn 1 without naming it, which is how a run of this example came to be
//! described as two model turns when it spent three. Everything it writes goes into a throwaway directory under the system
//! temp directory, which it removes on the way out (CEO §54). `HOME` is left alone, because the
//! provider credentials live there and a synthetic one would make this probe measure a sign-in
//! failure. It opens no audio device, plays nothing, and puts no window on screen — so it says
//! nothing about what the timer beside his reply reads (`ui/tests/question-timer.js` is that).
//!
//! Run:
//! ```text
//! cargo run -p richos-core --example first_reply_timing_e2e -- <engine> <delivered-runtime>
//! ```

use richos_core::live::LiveEvent;
use richos_core::{ecs::EcsBridge, native::{resolve_claude_bin, NativeCognition}};
use richos_core::{EntityId, EntityRegistry, Ledger, Source, Spine};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Instant;

/// Removed on the way out unless `RICHOS_PROBE_KEEP_FIXTURE` is set — the contract every
/// real-provider example in this directory keeps, and the CEO's §54.
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

/// Every tool call on his turn AHEAD of the reply, in arrival order, with its offset from the
/// send. The one term §55 is about.
///
/// `trace` is the same events WITHOUT the cut-off — every tool-call frame and his first words, in
/// arrival order — because since the app says the register's sentence itself, the evidence that it
/// did so is an ORDERING: his words arrive BEFORE the machinery record built from the very frame
/// they were read out of. A list that stops at his first word cannot show that.
#[derive(Default)]
struct BeforeHeSpoke {
    calls: Mutex<Vec<(String, f64)>>,
    trace: Mutex<Vec<(String, f64)>>,
    start: Mutex<Option<Instant>>,
    spoken: Mutex<bool>,
}
impl richos_core::machinery::MachineryObserver for BeforeHeSpoke {
    fn on_machinery(&self, record: &richos_core::machinery::MachineryRecord) {
        // **THE PERMISSION FRAME IS TRACED BUT NEVER SCORED**, because it is what decomposes the
        // ~2 s between the model finishing the register's arguments and the register answering.
        // The app's own desk answers it in-process, so whatever that 2 s is, this line says which
        // side of the desk it is on. It is not a tool call and the §55 rule never sees it.
        if record.kind == richos_core::machinery::MachineryKind::PermissionRequested {
            let since = self.start.lock().unwrap().map(|s| s.elapsed().as_secs_f64()).unwrap_or(0.0);
            self.trace.lock().unwrap().push((format!("permission asked+answered: {}", record.title), since));
            return;
        }
        if record.kind != richos_core::machinery::MachineryKind::ToolCall {
            return;
        }
        let since = self.start.lock().unwrap().map(|s| s.elapsed().as_secs_f64()).unwrap_or(0.0);
        let name = if record.title.is_empty() { record.kind.as_str().to_string() } else { record.title.clone() };
        {
            // The full trace, both sides of his first word. A closing record (no tool name on this
            // wire) carries the OUTCOME, which is what the app reads the sentence out of, so it is
            // labeled with its summary rather than with the kind's name.
            let mut trace = self.trace.lock().unwrap();
            let label = if record.title.is_empty() {
                format!("tool_call closed: {}", record.summary.clone().unwrap_or_default())
            } else {
                name.clone()
            };
            if trace.last().map(|(last, _)| last == &label) != Some(true) {
                trace.push((label, since));
            }
        }
        if *self.spoken.lock().unwrap() {
            return;
        }
        let mut calls = self.calls.lock().unwrap();
        // Merge the update frames for one call (§1.4 G2): a repeated title straight after itself
        // is the same step reported twice, not two steps.
        if calls.last().map(|(last, _)| last == &name) != Some(true) {
            calls.push((name, since));
        }
    }
}

/// The first instant Rich's own text reached the surface, and **every separate run of prose he
/// can see afterwards**.
///
/// The first instant is the §55 measure — a later delta is more of the same sentence. The RUNS
/// are here because the first run of this probe produced `"On it!On it!"`: two message runs, not
/// one doubled string, and the difference between those two readings is the difference between a
/// model that closed its turn with a second copy of its line and an app that rendered one line
/// twice. `message_id` is what separates them, so it is recorded rather than reasoned about.
#[derive(Default)]
struct FirstWords {
    at: Mutex<Option<Instant>>,
    /// `(message_id, offset of its first event, its text)`, in the order he saw them, and only
    /// what he can actually see — an internal or technical run is not his conversation.
    runs: Mutex<Vec<(String, f64, String)>>,
    start: Mutex<Option<Instant>>,
}
impl richos_core::live::LiveObserver for FirstWords {
    fn on_live_event(&self, event: &LiveEvent) {
        use richos_core::Visibility;
        let since = || self.start.lock().unwrap().map(|s: Instant| s.elapsed().as_secs_f64()).unwrap_or(0.0);
        match event {
            LiveEvent::MessageStarted { message_id, visibility: Visibility::Ceo, .. } => {
                let mut at = self.at.lock().unwrap();
                if at.is_none() {
                    *at = Some(Instant::now());
                }
                let mut runs = self.runs.lock().unwrap();
                if !runs.iter().any(|(id, _, _)| id == message_id) {
                    runs.push((message_id.clone(), since(), String::new()));
                }
            }
            LiveEvent::MessageDelta { message_id, text_delta, visibility: Visibility::Ceo, .. } => {
                let mut at = self.at.lock().unwrap();
                if at.is_none() {
                    *at = Some(Instant::now());
                }
                let mut runs = self.runs.lock().unwrap();
                match runs.iter_mut().find(|(id, _, _)| id == message_id) {
                    Some((_, _, text)) => text.push_str(text_delta),
                    None => runs.push((message_id.clone(), since(), text_delta.clone())),
                }
            }
            _ => {}
        }
    }
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    // **The app-owned MCP servers are served by THIS executable**, because `mcp_config` points
    // the child at `current_exe()` (`native.rs`). In the app that is `richos-tauri`; here it is
    // this example, so it answers the same three flags — a probe whose front desk came up
    // without the register would report a model failure that is really a wiring failure.
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
                richos_core::status_tools::run_stdio(&scope, &richos_core::screen::UnknownScreen)?;
                return Ok(());
            }
            _ => {}
        }
    }
    if args.len() != 2 {
        return Err("usage: first_reply_timing_e2e ENGINE DELIVERED_RUNTIME".into());
    }
    let engine = std::fs::canonicalize(&args[0])?;
    let root = Scratch(std::env::temp_dir().join(format!("richos first reply {}", uuid::Uuid::new_v4())));
    let data = root.0.join("app data");
    std::fs::create_dir_all(data.join("corpus/ceo/records"))?;

    let runtime = richos_core::runtime::EngineRuntime::load(&engine, Some(&PathBuf::from(&args[1])))?;
    let mut profile = richos_core::engine_profile::EngineProfile::prepare(&engine, &data, runtime.clone())?;
    let mut registry = EntityRegistry::from_existing_ids(&[EntityId::parse("depot")?]);
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
    let before = Arc::new(BeforeHeSpoke::default());
    struct Forward(Arc<FirstWords>, Arc<BeforeHeSpoke>);
    impl richos_core::live::LiveObserver for Forward {
        fn on_live_event(&self, event: &LiveEvent) {
            self.0.on_live_event(event);
            if matches!(event, LiveEvent::MessageStarted { .. } | LiveEvent::MessageDelta { .. }) {
                let mut spoken = self.1.spoken.lock().unwrap();
                if !*spoken {
                    let since = self.1.start.lock().unwrap().map(|s: Instant| s.elapsed().as_secs_f64()).unwrap_or(0.0);
                    self.1.trace.lock().unwrap().push(("HIS FIRST WORDS".to_string(), since));
                }
                *spoken = true;
            }
        }
    }
    spine.set_live_observer(Box::new(Forward(first_words.clone(), before.clone())));
    struct ForwardMachinery(Arc<BeforeHeSpoke>);
    impl richos_core::machinery::MachineryObserver for ForwardMachinery {
        fn on_machinery(&self, record: &richos_core::machinery::MachineryRecord) {
            self.0.on_machinery(record);
        }
    }
    spine.set_machinery_observer(Box::new(ForwardMachinery(before.clone())));

    let thread = spine.create_thread("First reply probe", &EntityId::parse("depot")?)?;
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

    // ================================================================================
    // THE PRIMING TURN, BEFORE HE TYPES (CEO §55)
    // ================================================================================
    //
    // **This is the ~8 s that used to be the front of his first message**, and it is a MODEL TURN
    // rather than a process start: `Spine::prime_front_desk` -> `prime_lease_if_needed` ->
    // `Cognition::reprime` -> `prompt_context_only`. The lease above is already spawned and its
    // handshake is already answered, which is exactly why the old turn 1 was still ~8 s slower
    // than turn 2. Measured here, named here, and spent BEFORE the first thing he says.
    //
    // `RICHOS_PROBE_UNPRIMED=1` skips it, which reproduces the shape every earlier run of this
    // probe measured — turn 1 paying for the priming while he waits. It is a mode rather than a
    // second run because a run costs his subscription three model turns.
    let unprimed = std::env::var_os("RICHOS_PROBE_UNPRIMED").is_some();
    let primed_in_ms = if unprimed {
        eprintln!("RICHOS_PROBE_UNPRIMED: the desk is NOT primed first — turn 1 pays for it, as it did before");
        None
    } else {
        let started = Instant::now();
        let verdict = spine.prime_front_desk(&thread);
        let elapsed = started.elapsed().as_secs_f64();
        eprintln!("---");
        eprintln!("front desk made ready before he types : {elapsed:.3} s  ({verdict:?})");
        match verdict {
            richos_core::spine::FrontDeskReady::Ready { .. } => Some(elapsed),
            other => return Err(format!("the desk was not made ready, so nothing below is measuring what it says: {other:?}").into()),
        }
    };

    // **One of each kind of thing he says that ends in a register row.** A task, which §55 is
    // written about, and a question the front desk cannot answer from the conversation or from
    // the status read, which §58 inherits §55's measure. Neither is a question about how work is
    // going — that one is answered from the read and is deliberately not this probe's subject.
    let says = [
        ("task", "Land the pricing branch and get the staging deploy done."),
        ("question", "Why has the nightly build been failing since Tuesday? I want to know what's actually causing it."),
    ];

    let mut rows = Vec::new();
    for (kind, text) in says {
        *first_words.at.lock().unwrap() = None;
        first_words.runs.lock().unwrap().clear();
        before.calls.lock().unwrap().clear();
        before.trace.lock().unwrap().clear();
        *before.spoken.lock().unwrap() = false;
        let sent = Instant::now();
        *before.start.lock().unwrap() = Some(sent);
        *first_words.start.lock().unwrap() = Some(sent);
        let turn = spine.submit_prompt(text, Source::Text)?;
        let turn_ended = sent.elapsed();
        let to_first_words = first_words.at.lock().unwrap().map(|at| at.duration_since(sent).as_secs_f64());
        let said = spine.ledger().turn(&turn).unwrap().assistant_text.trim().to_string();
        let ahead = before.calls.lock().unwrap().clone();
        let trace = before.trace.lock().unwrap().clone();
        let runs = first_words.runs.lock().unwrap().clone();

        eprintln!("---");
        eprintln!("he said    : {text}");
        eprintln!("Rich said  : {said:?}");
        match to_first_words {
            Some(d) => eprintln!("send -> first words : {d:.3} s"),
            None => eprintln!("send -> first words : NOT OBSERVED (no live text event)"),
        }
        eprintln!("send -> turn ended  : {:.3} s", turn_ended.as_secs_f64());
        if ahead.is_empty() {
            eprintln!("tool calls before he spoke : none — the time is the model's own latency");
        } else {
            eprintln!("tool calls before he spoke : {}", ahead.len());
            for (name, at) in &ahead {
                eprintln!("    {at:>7.3} s  {name}");
            }
        }
        eprintln!("runs of prose he can see : {}", runs.len());
        for (id, at, text) in &runs {
            eprintln!("    {at:>7.3} s  {text:?}  ({id})");
        }
        // **THE ORDERING THAT IS THE EVIDENCE.** His first words sit BETWEEN the register's
        // arguments and the machinery record that closes the register's row — which can only
        // happen if the app said them off that frame, as it went past.
        eprintln!("the turn, in arrival order:");
        for (label, at) in &trace {
            eprintln!("    {at:>7.3} s  {label}");
        }
        rows.push((kind, said, to_first_words, ahead, runs, trace));
    }

    // What the register actually holds. A right reply over a wrong record would be half the
    // feature, and the kind is what the timer and the status read use.
    let recorded = richos_core::assignment::read_all(&state_root, "depot", &thread)?;
    eprintln!("---");
    eprintln!("assignments written: {}", recorded.len());
    for row in &recorded {
        eprintln!("  kind={} state={} title={:?}", row.kind.as_str(), row.state.as_str(), row.title);
    }

    // ---- the rule ----------------------------------------------------------------------
    //
    // **Only the OPENING of the turn is scored here.** Which words he is handed is §58's leg
    // and `question_receipt_e2e` is its probe; what is measured here is the one thing §55
    // asked for and the doctrine could not enforce: nothing ahead of the reply that does not
    // have to be there, and the hand-over first when there is one.
    let mut failures = Vec::new();
    for (index, (kind, said, to_first_words, ahead, runs, trace)) in rows.iter().enumerate() {
        // **The lease's FIRST visible turn is a different measurement and gets its own budget.**
        // Measured on the same run: the model's first tool call at 11.714 s cold against 3.122 s
        // warm, all of it in front of the register. Handing the cold turn the warm budget would
        // fail the app for waking up; handing every turn the cold one would let a warm
        // regression through.
        // The lease's FIRST VISIBLE turn gets its own budget, still — it measured 7.998 s
        // against the warm turn's 6.358 s on a desk primed 2.768 s earlier (run A, 2026-09-18),
        // so the difference is real and it is no longer the priming turn. In
        // `RICHOS_PROBE_UNPRIMED=1` this same arm is what FAILS, by design: that mode puts the
        // priming turn back inside his first message, which measured 13.464 s to 15.714 s and is
        // over the 11 s this budget now is.
        let budget = if index == 0 {
            richos_core::first_reply::FIRST_TURN_BUDGET
        } else {
            richos_core::first_reply::FIRST_WORDS_BUDGET
        };
        for fault in richos_core::first_reply::first_reply_faults(ahead, *to_first_words, budget) {
            failures.push(format!("[{kind}] {fault}"));
        }
        // **SCORED, because this probe's own first run produced it.** With the checkpoint moved
        // to after the reply, the model closed its turn with a SECOND copy of the line it had
        // already said, and he read `"On it!On it!"`. Which words he is handed is §58's leg and
        // not this one's; being handed them twice is a defect this change introduced, so it is
        // caught here rather than left for him to find.
        if runs.len() > 1 {
            let texts: Vec<&str> = runs.iter().map(|(_, _, text)| text.trim()).collect();
            if texts.windows(2).any(|pair| pair[0] == pair[1] && !pair[0].is_empty()) {
                failures.push(format!("[{kind}] he was told the same thing twice: {texts:?}"));
            }
        }
        // **SCORED: HIS WORDS CAME FROM THE APP, AT THE REGISTER'S RETURN.** The app reads the
        // register's own answer off the wire and says the sentence itself, so on a turn that
        // handed work over his first words must arrive BEFORE the machinery record that closes
        // the register's row — both are built from the same frame, and the text is routed first.
        // A model that said them instead would put its words AFTER that record, a whole round
        // trip later (1.094 s and 1.427 s, measured on 2026-09-18 before this change).
        //
        // The rule is `first_reply::first_words_not_from_the_app`, shared with the unit test that
        // feeds it the PREVIOUS shipped state's own pair (6.034 s -> 7.128 s) and watches it go
        // red — so this arm is proven able to fail without spending a model turn on it.
        let answered_at = trace
            .iter()
            .find(|(label, _)| label.starts_with("tool_call closed:") && label.contains("\"recorded\":true"))
            .map(|(_, at)| *at);
        if let Some(fault) = richos_core::first_reply::first_words_not_from_the_app(answered_at, *to_first_words) {
            failures.push(format!("[{kind}] {fault}"));
        }
        // Reported, never scored: which words he is handed is the other ruling's subject. It is
        // printed so a drift in it is visible on the same run as the timing.
        eprintln!("[{kind}] reply was {said:?}");
    }
    if recorded.is_empty() {
        failures.push("nothing was written down at all, so neither turn exercised the register".into());
    }

    if !failures.is_empty() {
        for why in &failures {
            eprintln!("FAIL: {why}");
        }
        return Err(format!("{} check(s) failed", failures.len()).into());
    }
    eprintln!("---");
    eprintln!("PASS: the register was the first tool call on every turn that handed work over, and \
               nothing was discovered or written down ahead of his first word.");
    let slowest = rows.iter().filter_map(|(_, _, d, _, _, _)| *d).fold(0.0, f64::max);
    eprintln!(
        "slowest send -> first words this run: {slowest:.3} s (budgets: {:.0} s warm, {:.0} s on the \
         lease's first VISIBLE turn; §55: a few seconds, 35 s is a defect)",
        richos_core::first_reply::FIRST_WORDS_BUDGET.as_secs_f64(),
        richos_core::first_reply::FIRST_TURN_BUDGET.as_secs_f64()
    );
    match primed_in_ms {
        Some(seconds) => eprintln!(
            "the priming turn, which every figure above is now WITHOUT: {seconds:.3} s, spent before \
             he typed. Three model turns were spent by this run."
        ),
        None => eprintln!("no priming turn was run first, so turn 1 above paid for it — the old shape."),
    }
    Ok(())
}
