//! A REAL re-prime carrying REAL company memory, end to end, printed.
//!
//! Unit tests prove the seam against a fake compiler. This proves the seam against the
//! actual `loro-context.mjs`, the actual corpus, and the actual `Spine` priming path — the
//! only thing that can show that Tier C is genuinely wired rather than genuinely mocked.
//!
//! ```bash
//! export RICHOS_LORO_DIR=/path/to/loro          # the checkout holding bin/loro-context.mjs
//! export LORO_ROOT=/path/to/dogfood-checkout    # or LORO_CORPUS=/path/to/provisioned/corpus
//! export RICHOS_LORO_LANES=femcboost=femcboost  # optional; entity -> company lane, explicit
//! cargo run -p richos-core --example loro_reprime_demo -- "what did we decide about signing?"
//! ```
//!
//! **It prints; it never commits.** The output is the CEO's own memory and this repository
//! goes public, so the payload belongs in a private verification note or a terminal, never
//! in a file here. Nothing this example writes touches loro: the compiler is read-only by
//! structural invariant on its side, and the type used here holds no writer on this side.
//!
//! With nothing configured it says so and exits 0 — an install without a corpus is the
//! ordinary case, not a failure.

use richos_core::cognition::{Cognition, CognitionError, TurnItem};
use richos_core::entity::EntityId;
use richos_core::ledger::{Ledger, Source};
use richos_core::loro::CliContextCompiler;
use richos_core::spine::Spine;
use std::sync::{Arc, Mutex};

/// A lease that does nothing but KEEP the priming text it was handed, so the demonstration
/// prints the payload the spine really built rather than one reconstructed for printing.
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
        on_item(TurnItem::Text { seq: 0, text: "(demo lease: no model behind this)" });
        Ok("end_turn".into())
    }
}

fn main() {
    let topic = std::env::args().nth(1).unwrap_or_else(|| {
        "what did we decide about code signing and notarization?".to_string()
    });
    let entity = std::env::var("RICHOS_ENTITY").unwrap_or_else(|_| "richos".into());

    let compiler = match CliContextCompiler::from_env() {
        Ok(Some(c)) => {
            eprintln!("[demo] corpus root: {}", c.root().path().display());
            eprintln!("[demo] entity->lane map: {} entr(ies)", c.lanes().len());
            Some(c)
        }
        Ok(None) => {
            eprintln!(
                "[demo] no corpus configured (LORO_CORPUS / LORO_ROOT unset). The payload below is \
                 what an install WITHOUT company memory gets, which is the honest default."
            );
            None
        }
        Err(e) => {
            eprintln!("[demo] loro configured but unusable: {e}");
            None
        }
    };

    let path = std::env::temp_dir().join(format!("richos-loro-demo-{}.jsonl", std::process::id()));
    let _ = std::fs::remove_file(&path);
    let ledger = Ledger::open(&path).expect("open ledger");
    let mut spine = Spine::new(ledger);
    let entity_id = EntityId::parse(&entity).expect("RICHOS_ENTITY must be a registered entity id");
    spine.ensure_active_thread_in(&entity_id).expect("thread");

    if let Some(c) = compiler {
        spine.set_loro_context_compiler(Box::new(c));
    }

    let priming = Arc::new(Mutex::new(Vec::new()));
    spine.attach_lease(Box::new(CapturingLease {
        session_id: "demo-session".into(),
        priming: priming.clone(),
    }));

    // The CEO says one thing. That sentence becomes Tier A #3's current intent, which
    // becomes the compile topic (CONTEXT-CONTRACT.md §3), which produces Tier C.
    spine.submit_prompt(&topic, Source::Text).expect("submit");

    let primed = priming.lock().unwrap();
    println!("================ RE-PRIME PAYLOAD (what a fresh Rich is primed with) ================");
    for p in primed.iter() {
        println!("{p}");
        println!("--------------------------------------------------------------- {} chars", p.len());
    }
    let _ = std::fs::remove_file(&path);
}
