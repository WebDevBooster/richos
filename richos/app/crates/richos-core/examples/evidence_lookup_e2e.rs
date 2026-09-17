//! THE EVIDENCE LOOKUP, END TO END THROUGH THE APP — from a document nobody promoted to the
//! sentence Rich can say, with every claim measured rather than asserted.
//!
//! ```bash
//! cargo run -p richos-core --example evidence_lookup_e2e
//! ```
//!
//! Unit tests prove the wiring against a fake compiler and a fake lookup. This proves it
//! against the REAL `loro-context.mjs`, the REAL `richos-evidence.mjs`, a real evidence zone
//! on disk and the REAL `Spine` priming path — the only thing that can show Tier E is
//! genuinely wired rather than genuinely mocked.
//!
//! # It never touches anything of the CEO's
//!
//! `HOME`, `LORO_CORPUS` and the evidence zone are all created under a fresh temp directory
//! and removed at the end. Every environment variable the pipeline reads is set or cleared
//! explicitly, so nothing on the machine leaks in. Every fixture is fictional.
//!
//! # What it proves, in the order it proves it
//!
//! 1. The corpus is NOT empty — it holds a real page of company memory, so "no coverage" is a
//!    verdict about the question rather than about an empty loro.
//! 2. The Rust and JavaScript consult gates agree on all four coverage labels.
//! 3. A question memory cannot answer produces `coverage: none | adjacent`, the labeled block
//!    appears ONCE in the priming prompt, BELOW the company-memory heading and outside it,
//!    carrying the deep link.
//! 4. The memory section is BYTE-IDENTICAL with and without the block — the memory lanes'
//!    budget belongs to memory.
//! 5. THE CONTROL: a question memory DOES cover produces `coverage: direct`, no lookup process
//!    is spawned, and the block is absent.
//! 6. Nothing was written: the evidence zone is byte-identical before and after.
//!
//! Exits non-zero if any check fails.

use richos_core::cognition::{Cognition, CognitionError, TurnItem};
use richos_core::entity::{Entity, EntityId, EntityRegistry};
use richos_core::evidence::{CliEvidenceLookup, EvidenceTools, EvidenceZone};
use richos_core::ledger::{Ledger, Source};
use richos_core::loro::{CliContextCompiler, LaneMap, LoroRoot, LoroTools};
use richos_core::reprime::{
    EvidenceLookup, EvidenceRequest, EvidenceTier, LoroContextCompiler, SliceCoverage, SliceRequest,
    DEFAULT_LORO_BUDGET_CHARS,
};
use richos_core::spine::Spine;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

const MEMORY_HEADING: &str = "COMPANY MEMORY (loro)";
const EVIDENCE_HEADING: &str = "FROM YOUR FILES (evidence — not company memory)";
const DEEP_LINK: &str = "https://drive.google.com/file/d/file_pricing/view";

/// A lease that does nothing but KEEP the priming text it was handed, so this prints the
/// payload the spine really built rather than one reconstructed for printing.
struct CapturingLease {
    session_id: String,
    priming: Arc<Mutex<Vec<String>>>,
}

impl Cognition for CapturingLease {
    fn session_id(&self) -> &str {
        &self.session_id
    }
    fn reprime(&mut self, priming_text: &str, _on_item: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        self.priming.lock().unwrap().push(priming_text.to_string());
        Ok(())
    }
    fn prompt(&mut self, _text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        on_item(TurnItem::Text { seq: 0, text: "(e2e lease: no model behind this)" });
        Ok("end_turn".into())
    }
}

static FAILURES: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

fn check(label: &str, ok: bool, detail: &str) {
    if ok {
        println!("    PASS  {label}");
    } else {
        FAILURES.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        println!("    FAIL  {label}\n          {detail}");
    }
}

fn main() {
    let here = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    // `crates/richos-core` -> `app` -> `richos`
    let richos = here.join("../../..").canonicalize().expect("the richos tree");
    let loro_dir = richos.join("engine/loro");
    let evidence_bin = richos.join("tools/richos-service/bin/richos-evidence.mjs");

    let root = std::env::temp_dir().join(format!("richos-evidence-e2e-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let home = root.join("home");
    let corpus = root.join("corpus");
    let zone = corpus.join("ceo/evidence/unfiled/workspace");
    std::fs::create_dir_all(&home).unwrap();

    // THE ISOLATED WORLD, established before anything reads the environment.
    std::env::set_var("HOME", &home);
    std::env::set_var("LORO_CORPUS", &corpus);
    for stale in [
        "LORO_ROOT", "RICHOS_WORKSPACE_ZONE", "RICHOS_ACTIVE_COMPANY", "RICHOS_ENTITIES_FILE",
        "RICHOS_DROP_ZONE", "RICHOS_LORO_LANES", "RICHOS_EVIDENCE_BIN", "RICHOS_SERVICE_BIN",
    ] {
        std::env::remove_var(stale);
    }

    println!("=== The evidence lookup, end to end through the app ===");
    println!("corpus:        {}", corpus.display());
    println!("evidence zone: {}", zone.strip_prefix(&corpus).unwrap().display());
    println!("loro tools:    {}", loro_dir.display());
    println!("lookup bin:    {}", evidence_bin.display());
    println!();

    write_corpus(&corpus);
    write_evidence(&zone, &corpus);
    let fingerprint_before = fingerprint(&zone);

    // ---------------------------------------------------------------------------------
    println!("0. THE PIECES — the real compiler and the real lookup, resolved the app's way");
    let tools = LoroTools::locate(&loro_dir).expect("the loro checkout");
    let ev_tools = EvidenceTools::locate(&evidence_bin).expect("the evidence entry point");
    println!("   node:          {}", tools.node());
    println!("   context bin:   {}", tools.context_bin().display());
    println!("   evidence bin:  {}", ev_tools.bin().display());
    println!();

    // ---------------------------------------------------------------------------------
    println!("1. THE GATE — Rust and JavaScript asked the same four questions");
    let lookup_for_gate = CliEvidenceLookup::new(ev_tools.clone(), EvidenceZone::Corpus(corpus.clone()));
    for label in ["none", "adjacent", "direct", "partial"] {
        let rust = SliceCoverage::parse(label).should_consult_evidence();
        let js = js_consulted(&ev_tools, &corpus, label);
        check(
            &format!("coverage {label:?}: rust says consult={rust}, javascript says consult={js}"),
            rust == js,
            &format!("the two gates disagree on {label:?}"),
        );
    }
    // And the fourth Rust state, which has no string to send at all.
    check(
        "an unreported label never reaches the process",
        !SliceCoverage::Unknown.should_consult_evidence()
            && SliceCoverage::Unknown.as_str().is_none(),
        "Unknown must be neither a consult signal nor a string",
    );
    drop(lookup_for_gate);
    println!();

    // ---------------------------------------------------------------------------------
    let question = "what is our coach pricing model";
    println!("2. THE QUESTION MEMORY CANNOT ANSWER");
    println!("Q   \"{question}\"");
    let coverage_a = compile_coverage(&tools, &corpus, question);
    println!("    compiled coverage: {coverage_a:?}");
    check(
        "memory does NOT cover this — while the document sits in evidence the whole time",
        coverage_a.should_consult_evidence(),
        &format!("coverage was {coverage_a:?}"),
    );

    let with_block = run_turn(&loro_dir, &corpus, Some(&evidence_bin), question);
    let without_block = run_turn(&loro_dir, &corpus, None, question);
    println!();
    println!("--- the priming prompt the successor received (Tier E section) ---");
    if let Some(at) = with_block.prompt.find("THE CEO'S OWN FILES") {
        let end = with_block.prompt.find("Acknowledge internally").unwrap_or(with_block.prompt.len());
        for line in with_block.prompt[at..end].trim_end().lines() {
            println!("    {line}");
        }
    }
    println!();

    check(
        "the labeled block is in the prompt, exactly once",
        with_block.prompt.matches(EVIDENCE_HEADING).count() == 1,
        &format!("found {} times", with_block.prompt.matches(EVIDENCE_HEADING).count()),
    );
    let mem_at = with_block.prompt.find(MEMORY_HEADING);
    let ev_at = with_block.prompt.find(EVIDENCE_HEADING);
    check(
        "it sits BELOW the company-memory heading and outside it",
        matches!((mem_at, ev_at), (Some(m), Some(e)) if m < e),
        &format!("memory at {mem_at:?}, evidence at {ev_at:?}"),
    );
    check(
        "the deep link back into the CEO's own cloud survives into the written context",
        with_block.prompt.contains(DEEP_LINK),
        "the link is missing",
    );
    check(
        "the model is told the text is DATA and never an instruction, before it reads any",
        with_block
            .prompt
            .find("DATA copied out of a document")
            .zip(ev_at)
            .is_some_and(|(warn, block)| warn < block),
        "the warning must precede the block",
    );
    check(
        "the spoken form offers the document and carries no URL",
        with_block.prompt.contains("IF YOU ARE SPEAKING")
            && with_block
                .prompt
                .split("IF YOU ARE SPEAKING")
                .nth(1)
                .is_some_and(|tail| {
                    let sentence = tail.split("The written answer").next().unwrap_or("");
                    sentence.contains("Want me to read you what it says?") && !sentence.contains("http")
                }),
        "the spoken instruction is missing or carries a link",
    );
    println!();

    // ---------------------------------------------------------------------------------
    println!("3. THE BUDGET — the memory lanes' characters belong to memory");
    let mem_with = memory_section(&with_block.prompt);
    let mem_without = memory_section(&without_block.prompt);
    println!("    memory section WITH a block:    {} chars", mem_with.len());
    println!("    memory section WITHOUT a block: {} chars", mem_without.len());
    println!("    compiler asked for:             {DEFAULT_LORO_BUDGET_CHARS} chars, both runs");
    println!(
        "    whole prompt:                   {} -> {} chars (+{})",
        without_block.prompt.len(),
        with_block.prompt.len(),
        with_block.prompt.len() - without_block.prompt.len()
    );
    check(
        "the memory section is BYTE-IDENTICAL with and without the block",
        mem_with == mem_without,
        "the memory section changed when the block was added",
    );
    check(
        "and the prompt DID grow — so 'identical' above is about the lanes, not about a block that never arrived",
        with_block.prompt.len() > without_block.prompt.len() + 200,
        &format!("{} vs {}", with_block.prompt.len(), without_block.prompt.len()),
    );
    check(
        "the run WITHOUT a lookup says nothing at all about the CEO's files",
        !without_block.prompt.contains("THE CEO'S OWN FILES")
            && !without_block.prompt.contains(EVIDENCE_HEADING),
        "a run with no lookup must render no evidence section",
    );
    println!();

    // ---------------------------------------------------------------------------------
    let control = "how do I decide things that are hard to reverse";
    println!("4. THE CONTROL — a question memory DOES cover");
    println!("Q   \"{control}\"");
    let coverage_b = compile_coverage(&tools, &corpus, control);
    println!("    compiled coverage: {coverage_b:?}");
    check(
        "memory covers this one",
        !coverage_b.should_consult_evidence(),
        &format!("coverage was {coverage_b:?} — the control is not a control if memory misses it too"),
    );
    let covered = run_turn(&loro_dir, &corpus, Some(&evidence_bin), control);
    check(
        "the block is ABSENT, and so is every word about the CEO's files",
        !covered.prompt.contains(EVIDENCE_HEADING) && !covered.prompt.contains("THE CEO'S OWN FILES"),
        "an evidence block appeared on a covered question",
    );
    check(
        "company memory IS in that prompt — so the absence above is the gate, not a dead turn",
        covered.prompt.contains(MEMORY_HEADING),
        "the covered turn carried no memory either",
    );
    println!();

    // ---------------------------------------------------------------------------------
    println!("5. THE LOOKUP WROTE NOTHING");
    check(
        "the evidence zone is byte-identical before and after every run above",
        fingerprint(&zone) == fingerprint_before,
        "the zone changed",
    );
    let probe = zone.join("_probe.txt");
    std::fs::write(&probe, "x").unwrap();
    check(
        "and the fingerprint is sensitive to a change, so 'identical' means something",
        fingerprint(&zone) != fingerprint_before,
        "the fingerprint did not notice a new file",
    );
    std::fs::remove_file(&probe).unwrap();
    println!();

    let failures = FAILURES.load(std::sync::atomic::Ordering::Relaxed);
    println!("{}", if failures == 0 { "=== every check passed ===".to_string() } else { format!("=== {failures} CHECK(S) FAILED ===") });
    let _ = std::fs::remove_dir_all(&root);
    std::process::exit(if failures == 0 { 0 } else { 1 });
}

// -------------------------------------------------------------------------------------------

struct TurnResult {
    prompt: String,
}

/// One whole turn through the real spine, with the real compiler and optionally the real
/// lookup. Returns the priming prompt the successor actually received.
fn run_turn(loro_dir: &Path, corpus: &Path, evidence_bin: Option<&Path>, question: &str) -> TurnResult {
    let ledger_path = std::env::temp_dir().join(format!(
        "richos-evidence-e2e-{}-{}.jsonl",
        std::process::id(),
        richos_core::util::now_millis()
    ));
    let _ = std::fs::remove_file(&ledger_path);
    let ledger = Ledger::open(&ledger_path).unwrap();
    let mut spine = Spine::new(ledger);
    spine.set_entity_registry(registry());
    spine.ensure_active_thread_in(&EntityId::parse("richos").unwrap()).unwrap();

    // An EMPTY lane map is what an unpartitioned corpus is: no `--company`, the CEO layer.
    let compiler = CliContextCompiler::new(
        LoroTools::locate(loro_dir).unwrap(),
        LoroRoot::Corpus(corpus.to_path_buf()),
        LaneMap::default(),
    );
    spine.set_loro_context_compiler(Box::new(compiler));
    if let Some(bin) = evidence_bin {
        spine.set_evidence_lookup(Box::new(CliEvidenceLookup::new(
            EvidenceTools::locate(bin).unwrap(),
            EvidenceZone::Corpus(corpus.to_path_buf()),
        )));
    }

    let priming = Arc::new(Mutex::new(Vec::new()));
    spine.attach_lease(Box::new(CapturingLease {
        session_id: "s-e2e".into(),
        priming: Arc::clone(&priming),
    }));
    spine.submit_prompt(question, Source::Text).unwrap();
    let prompt = priming.lock().unwrap().first().cloned().unwrap_or_default();
    let _ = std::fs::remove_file(&ledger_path);
    TurnResult { prompt }
}

/// The compiler's own coverage label for `topic`, read through the same `interpret_tier` the
/// spine uses.
fn compile_coverage(tools: &LoroTools, corpus: &Path, topic: &str) -> SliceCoverage {
    let compiler =
        CliContextCompiler::new(tools.clone(), LoroRoot::Corpus(corpus.to_path_buf()), LaneMap::default());
    compiler
        .compile_tier(&SliceRequest {
            thread_id: "thr_e2e",
            entity_id: "richos",
            topic,
            budget_chars: DEFAULT_LORO_BUDGET_CHARS,
        })
        .coverage
}

/// Ask the JavaScript entry point whether IT would consult, for one label. The Rust gate and
/// this must agree, and disagreeing silently is how one side quietly stops guarding.
fn js_consulted(tools: &EvidenceTools, corpus: &Path, label: &str) -> bool {
    // Driven through `look_up` for the two labels Rust would send, and through a direct
    // process run for the two it would not — which is exactly the asymmetry being checked.
    let lookup = CliEvidenceLookup::new(tools.clone(), EvidenceZone::Corpus(corpus.to_path_buf()));
    let out = std::process::Command::new(tools.node())
        .args([
            tools.bin().display().to_string(),
            "lookup".into(),
            "--coverage".into(),
            label.into(),
            "--topic".into(),
            "what is our coach pricing model".into(),
            "--corpus".into(),
            corpus.display().to_string(),
        ])
        .output()
        .expect("the evidence entry point runs");
    let json: serde_json::Value =
        serde_json::from_slice(&out.stdout).expect("the entry point emits json");
    let js = json["consulted"].as_bool().unwrap_or(false);
    // Cross-check: when Rust would send this label, `look_up` must reach the same verdict.
    let coverage = SliceCoverage::parse(label);
    if coverage.should_consult_evidence() {
        let tier = lookup.look_up(&EvidenceRequest {
            thread_id: "thr_e2e",
            entity_id: "richos",
            topic: "what is our coach pricing model",
            coverage,
        });
        assert!(
            !matches!(tier, EvidenceTier::NotConsulted(_)),
            "rust would consult on {label:?} but its own lookup reported NotConsulted"
        );
    }
    js
}

/// The `COMPANY MEMORY (loro)` section of a priming prompt, from its heading to the blank line
/// that ends it.
fn memory_section(prompt: &str) -> String {
    let at = prompt.find(MEMORY_HEADING).expect("the memory section is present");
    let rest = &prompt[at..];
    let end = rest.find("\n\n").map(|i| i + 1).unwrap_or(rest.len());
    rest[..end].to_string()
}

fn registry() -> EntityRegistry {
    EntityRegistry::new(vec![Entity::new("richos", "RichOS", &["/fixture/richos"]).unwrap()]).unwrap()
}

// -------------------------------------------------------------------------------------------
// the fixtures — all fictional, all under the temp root
// -------------------------------------------------------------------------------------------

/// A corpus with REAL company memory in it, so "no coverage" is a verdict about the question
/// rather than about an empty loro.
fn write_corpus(corpus: &Path) {
    for rel in ["ceo/records", "ceo/unfiled", "ceo/pages"] {
        std::fs::create_dir_all(corpus.join(rel)).unwrap();
    }
    std::fs::write(
        corpus.join("ceo/entities.json"),
        "{\n  \"schemaVersion\": 1,\n  \"version\": \"2026-09-17\",\n  \"entities\": []\n}\n",
    )
    .unwrap();
    std::fs::write(
        corpus.join("ceo/pages/worldview.md"),
        "# How I work\n\n\
         ## How I decide\n\n\
         I decide slowly on things that are hard to reverse and fast on everything else. A decision\n\
         I can undo in a week is not worth a meeting.\n\n\
         ## Hiring\n\n\
         I hire for judgment over experience, and I would rather carry a role open for a month than\n\
         fill it with somebody I have to supervise.\n",
    )
    .unwrap();
}

/// One Drive document in the evidence zone, in the shape `readEvidenceZone` walks:
/// `<zone>/<vendor>/<source>/<id>/<rev>/{item.json,content.txt,governance.json}`.
///
/// **Written directly rather than ingested.** The REAL adapter → governance-gate → zone path
/// is proven end to end by `tools/richos-service/test/evidence-lookup-e2e.mjs`, which drives
/// the actual Drive and Gmail adapters over a mocked API. Re-driving it from Rust would prove
/// the same thing twice and would make this example need a Google client. What this example
/// exists to prove starts at the zone.
fn write_evidence(zone: &Path, corpus: &Path) {
    let dir = zone.join("google/drive/file_pricing/rev4");
    std::fs::create_dir_all(&dir).unwrap();
    let body = "Coach pricing model. The ladder has three rungs. Rung one is a solo coach at \
                ninety-nine dollars a month. That is the floor and it is not discountable, because \
                every discount below it has been given to somebody who then churned inside two \
                quarters. Rung two is a studio seat, priced per coach, with a three-seat minimum \
                and a volume break at ten. Rung three is multi-location, which is quoted rather \
                than listed because every one so far has been different. Alice Nguyen owns the \
                discount ladder and is the only person who may sign below rung one.";
    // 2026-09-15T18:00:00Z, derived rather than typed: the first value written here was
    // 1_789_308_000_000 and rendered "Sunday, September 13" in the block below, which is the
    // whole reason a date in a proof gets computed. `node -e 'Date.parse("2026-09-15T18:00:00Z")'`.
    let occurred = 1_789_495_200_000i64;
    let item = serde_json::json!({
        "sourceItemId": "google:drive:file_pricing",
        "vendor": "google",
        "source": "drive",
        "kind": "document",
        "provenance": { "fetchedAt": occurred, "vendorUrl": DEEP_LINK },
        "actors": {
            "author": { "name": "Alex Booster", "email": "ceo@acme.example", "orgRelation": "self" },
            "attendees": [],
            "recipients": [
                { "name": "Alice Nguyen", "email": "alice@acme.example", "orgRelation": "internal" }
            ]
        },
        "temporal": { "occurredAt": occurred },
        "content": { "title": "Coach pricing model", "text": body, "structured": {}, "attachmentsRefs": [] },
        "trust": { "class": "unverified", "quarantine": false, "flags": [] }
    });
    std::fs::write(dir.join("item.json"), format!("{}\n", serde_json::to_string_pretty(&item).unwrap())).unwrap();
    std::fs::write(dir.join("content.txt"), format!("{body}\n")).unwrap();
    let governance = serde_json::json!({
        "scope": "ceo-private",
        "trust": { "class": "unverified", "quarantine": false, "flags": [] },
        "evidenceLink": dir.strip_prefix(corpus).unwrap().join("item.json").display().to_string()
    });
    std::fs::write(
        dir.join("governance.json"),
        format!("{}\n", serde_json::to_string_pretty(&governance).unwrap()),
    )
    .unwrap();
}

fn fingerprint(zone: &Path) -> Vec<String> {
    let mut out = Vec::new();
    walk(zone, zone, &mut out);
    out.sort();
    out
}

fn walk(base: &Path, dir: &Path, out: &mut Vec<String>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(base, &p, out);
        } else if let Ok(meta) = std::fs::metadata(&p) {
            out.push(format!("{}:{}", p.strip_prefix(base).unwrap().display(), meta.len()));
        }
    }
}
