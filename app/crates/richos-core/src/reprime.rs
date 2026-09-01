//! Session-continuity FOUNDATION — the re-prime payload (P1.4, foundation only).
//!
//! The durable Rich is the APP; a Claude session is a swappable compute lease
//! (continuity design §1.1). When a lease is (re)spawned, the app injects a re-prime
//! payload as an INTERNAL, NON-RENDERED priming turn so the successor resumes as the
//! SAME Rich, mid-conversation — no re-ask, no amnesia, no false attribution.
//!
//! This module builds the payload and renders it to the priming-turn text. Full
//! turn-boundary rotation on a context watermark + self-authored handoff summaries
//! are a LATER leg; the seam is here (Spine::reprime_current_session) so they drop in.

use crate::entity::ThreadBinding;
use crate::ledger::{ActionStatus, Ledger, LedgerError, Source, TurnState};
use crate::worker_status::Unattributed;
use serde::Serialize;

/// What Tier C asks the compiler for. A slice is ALWAYS topical — `CONTEXT-CONTRACT.md`
/// §1: *"there is no compile all of loro"* — so a thread id alone was never a legal
/// request, and the seam used to pass one. §3 says it plainly: pass the CEO's **current
/// intent**, one or two sentences of natural language; a long tail dilutes `coverage`
/// because every incidental word enlarges the denominator, so a squarely-relevant slice
/// gets labelled `adjacent` purely for having been asked verbosely.
///
/// `entity_id` rides along because a slice is also SCOPED (ECS §3.5). What the compiler
/// side does with it is its own business — narrow a lane, or refuse — but it must be told,
/// and it cannot recover the entity from the thread id.
#[derive(Debug, Clone, Copy)]
pub struct SliceRequest<'a> {
    /// The conversation being re-primed. Provenance and logging, not ranking.
    pub thread_id: &'a str,
    /// The entity area this thread is bound to, immutably (ECS §3.4).
    pub entity_id: &'a str,
    /// The CEO's current intent, in his words. Never empty — see [`RePrimePayload::topic`].
    pub topic: &'a str,
    /// Hard cap on the returned text, in CHARACTERS (`CONTEXT-CONTRACT.md` §3: characters,
    /// not tokens, because characters are model-agnostic and exactly checkable).
    pub budget_chars: usize,
}

/// Tier C's FOUR states, and three of them are not "a slice".
///
/// This is the rule the ACTION LEDGER and LIVE WORKER STATE sections of this payload
/// already follow, applied to company memory: **an absence must never read to a successor
/// as a denial.** "loro has nothing on this" (a real, checked answer), "loro could not be
/// consulted" (an unknown) and "this install has no corpus configured" (a different
/// unknown) are three different facts, and collapsing them into one silent `None` is how a
/// fresh Rich ends up asserting the company has no position on something it decided.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub enum LoroTier {
    /// No compiler is attached — the default, and what an install with no corpus
    /// configured keeps. Continuity holds; grounding is thinner (continuity §2.3/§4, §8 Q4).
    NotWired,
    /// Compiled, and loro had something to say. The string is `slice.text` VERBATIM —
    /// `CONTEXT-CONTRACT.md` §3: it is self-contained and carries its own
    /// `COMPANY MEMORY (loro) — bearing on: …` heading, so it is injected as its own block
    /// with no prefix. Adding one doubles the heading.
    Slice(String),
    /// Compiled, exit 0, `thin: true` — loro genuinely holds nothing bearing on the topic.
    /// The string is loro's OWN one-line honesty text (§5), which already ends *"Do not
    /// assume company facts — ask the CEO or check a live system."* That sentence is the
    /// answer; fabricating a slice in its place is the failure this variant exists to make
    /// impossible.
    NothingRecorded(String),
    /// A compiler is attached and could not produce a trustworthy answer: the process
    /// failed to spawn, exited non-zero, returned an unsupported `schemaVersion`, or the
    /// slice was REFUSED by the entity/lane re-assertion. Carries the reason, because a
    /// successor told nothing at all would infer "nothing recorded".
    Unavailable(String),
}

impl LoroTier {
    /// The injectable text, when there is one. `None` for both unknown states.
    pub fn text(&self) -> Option<&str> {
        match self {
            LoroTier::Slice(t) | LoroTier::NothingRecorded(t) => Some(t),
            _ => None,
        }
    }

    /// True only for a checked, positive answer from loro.
    pub fn is_slice(&self) -> bool {
        matches!(self, LoroTier::Slice(_))
    }
}

/// The Tier-C SEAM (continuity §2.3/§4, §8 Q4): the loro Context Compiler is loro-owned
/// and lives outside this repo (`richos-hq/loro/`, behind a versioned
/// `CONTEXT-CONTRACT.md`); richos-core stays out of it. This trait is the CONTRACT that
/// lets it plug in with zero coupling — implement it, call
/// `Spine::set_loro_context_compiler`, done. The shipped implementation is
/// [`crate::loro::CliContextCompiler`], which shells out to the contract's own entry point.
///
/// **It cannot fail the turn.** The return type has no error arm on purpose:
/// `CONTEXT-CONTRACT.md` §3 requires that a non-zero exit degrades to no slice and *never*
/// fails the turn, and a `Result` invites a caller to `?` it into the rotation path — where
/// a memory miss would take down a session rotation the CEO is not supposed to be able to
/// see. Every failure is an [`LoroTier::Unavailable`] carrying its reason instead.
pub trait LoroContextCompiler: Send {
    /// Compile the small, topical slice for `req` (§2.1 #8: strategy, constraints, prior
    /// decisions, CEO preferences bearing on the ACTIVE thread — not all of loro).
    fn compile_slice(&self, req: &SliceRequest<'_>) -> LoroTier;
}

/// How many recent turns carry VERBATIM (Tier A #4). Small by design — the payload
/// is billed on every rotation under BYO-Anthropic, so it is budgeted, not dumped.
pub const DEFAULT_TAIL_TURNS: usize = 8;

/// Tier C's character budget. `CONTEXT-CONTRACT.md` §3 asks for *"the number the payload
/// budgeter can afford after Tiers A and B"* and calls 800–1600 the sane band; **there is
/// no payload budgeter**, so this is a constant sitting at the contract's own default, and
/// it is named as a constant rather than dressed up as a measurement.
///
/// What it costs, MEASURED rather than asserted (2026-08-29,
/// `examples/loro_reprime_demo.rs` against the 515-record dogfood corpus, one CEO turn, no
/// action ledger): the compiled slice was **911 chars** of a **3,241-char** payload —
/// 28.1%. Had it filled its cap the payload would be 3,530 chars and Tier C 34.0% of it.
/// So Tier C is the single largest lever in the payload, and the number to turn first if a
/// re-prime ever has to get cheaper. At the contract's ~4 chars/token guide, 1200 chars is
/// ≈300 tokens.
pub const DEFAULT_LORO_BUDGET_CHARS: usize = 1200;

#[derive(Debug, Clone, Serialize)]
pub struct TurnView {
    pub role: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ActionView {
    pub kind: String,
    pub detail: String,
    pub status: String,
}

/// The distilled working set injected into a fresh session (continuity design §2.1).
#[derive(Debug, Clone, Serialize)]
pub struct RePrimePayload {
    // Tier A — always, verbatim, small
    pub identity_assertion: String,
    pub pending_decisions: Vec<String>,
    pub current_intent: Option<String>,
    pub recent_tail: Vec<TurnView>,
    // Tier B — summarized / structured
    pub rolling_summary: Option<String>,
    pub action_ledger_digest: Vec<ActionView>,
    pub worker_state: Vec<String>,
    /// Set when NO team directory could be attributed to this session, naming the reason
    /// (`worker_status.rs`). `worker_state` is then empty for a reason that is NOT "there
    /// are no workers", and `to_priming_prompt` says exactly that instead of falling
    /// silent — the same rule the ACTION LEDGER section already follows.
    pub worker_state_unknown: Option<Unattributed>,
    // Tier C — compiled, minimal. FOUR states, never one silent Option (see `LoroTier`).
    pub loro: LoroTier,
}

impl RePrimePayload {
    /// Assemble the payload for a conversation thread from the shared ledger.
    ///
    /// Tier C is [`LoroTier::NotWired`] here and is filled in by the caller
    /// (`Spine::compile_loro_tier`), because compiling it needs a TOPIC and the topic is
    /// derived from the payload this function returns — Tier A #3's current intent, or
    /// failing that the last thing the CEO actually said. Assembling Tiers A/B first and
    /// compiling Tier C from them is the only ordering that can produce a topical request
    /// (`CONTEXT-CONTRACT.md` §1: a slice is always topical).
    ///
    /// `session_id` is the compute lease this payload is being built for. It is what the
    /// worker section is ATTRIBUTED by: the team directory is derived from it
    /// (`worker_status::resolve_team_dir`), never picked off the filesystem. `None` — no
    /// lease — yields an explicitly-unknown worker section rather than an empty one, and
    /// performs no filesystem read at all.
    ///
    /// SCOPED (ECS §3.3–3.5): the payload is assembled from a [`ThreadBinding`], not a
    /// bare thread id, and every ingredient is read through the entity guard. A re-prime
    /// is the highest-leverage cross-entity leak in the app — whatever lands here is
    /// asserted to a fresh session as authoritative — so an unbound thread cannot be
    /// primed at all, and no other entity's turns or actions can reach the prompt.
    pub fn assemble(
        ledger: &Ledger,
        binding: &ThreadBinding,
        tail_turns: usize,
        session_id: Option<&str>,
    ) -> Result<Self, LedgerError> {
        // Superseded turns (§5.3 mid-turn-crash replay) are excluded from the working
        // set entirely — a successfully-replayed turn is no longer "unfinished," and its
        // dead predecessor shouldn't pollute the verbatim tail either.
        let scoped = ledger.thread_turns_scoped(binding)?;
        let turns: Vec<_> = scoped
            .into_iter()
            .filter(|t| t.source != Source::Internal && t.superseded_by.is_none())
            .collect();
        let thread_id = binding.thread_id();

        // Tier A #4 — last N verbatim (user + assistant).
        let mut recent_tail = Vec::new();
        for t in turns.iter().rev().take(tail_turns).rev() {
            // A Proactive turn is Rich speaking UNPROMPTED — there was no CEO prompt, and
            // `user_text` is empty by construction (see `Event::ProactiveMessage` in
            // ledger.rs). Emitting the user line anyway put a PHANTOM BLANK CEO UTTERANCE
            // in front of it ("  user: " with nothing after the colon), which reads to a
            // successor as "the CEO said something and Rich answered" — mis-attributing
            // Rich's own initiative to the CEO. That is the same false-attribution class
            // §6 exists to structurally exclude, so the line is omitted and the reply is
            // labelled for what it was.
            if t.source != Source::Proactive {
                recent_tail.push(TurnView { role: "user".into(), text: t.user_text.clone() });
            }
            if !t.assistant_text.is_empty() {
                let role = if t.source == Source::Proactive { "assistant (unprompted)" } else { "assistant" };
                recent_tail.push(TurnView { role: role.into(), text: t.assistant_text.clone() });
            }
        }

        // Tier A #3 — current intent: the most recent not-yet-completed ask.
        let current_intent = turns
            .iter()
            .rev()
            .find(|t| matches!(t.state, TurnState::Received | TurnState::InFlight))
            .map(|t| t.user_text.clone());

        // Tier A #2 — pending decisions: interrupted turns are open loops a successor
        // must not silently drop (a fuller heuristic — "Rich asked, CEO hasn't answered"
        // — lands with the rolling-summary work).
        let pending_decisions: Vec<String> = turns
            .iter()
            .filter(|t| t.state == TurnState::Interrupted)
            .map(|t| format!("Unfinished: {}", t.user_text))
            .collect();

        // Tier B #5 — rolling summary of everything BEFORE the verbatim tail.
        // Continuity §2.4 recommends BOTH: an always-on deterministic structured digest
        // as the crash-safe floor, UPGRADED to a self-authored handoff summary on clean
        // rotation (highest fidelity — the session that lived the conversation distills
        // it). Prefer the handoff summary when one exists for this thread; otherwise fall
        // back to the structured digest so a thread that has never rotated (or whose
        // outgoing lease couldn't be asked, e.g. it already crashed) still carries SOME
        // rolling context.
        let older = turns.len().saturating_sub(tail_turns);
        let rolling_summary = match ledger.handoff_summary(thread_id) {
            Some(summary) => Some(summary.to_string()),
            None if older > 0 => Some(format!(
                "{older} earlier turn(s) in this thread precede the verbatim tail below; \
                 topics and decisions from them are recorded in the ledger and can be pulled on demand."
            )),
            None => None,
        };

        // Tier B #6 — action ledger digest (anti-false-attribution authority).
        // CEO-FACING actions only: internal machinery actions (lease rotation, re-prime
        // injection, crash recovery) are durably recorded in the same ledger but are
        // NEVER injected here — the identity assertion forbids the successor from ever
        // revealing or referencing session rotation (§6.2), so handing it a line reading
        // "[done] session_rotation" under a header that calls the section authoritative
        // ground truth for "what Rich has done" would manufacture that leak.
        //
        // ENTITY-SCOPED (ECS §3.5, UX §22 "cross-entity context must not be faked). The
        // digest used to be the WHOLE ledger's CEO-facing actions, which meant every
        // rotation injected every entity's actions into every entity's session under a
        // header calling them authoritative. Scoping is by entity, not by thread, so
        // nothing that was visible within an entity disappears — only the cross-entity
        // leak closes.
        let action_ledger_digest: Vec<ActionView> = ledger
            .ceo_facing_actions_for_entity(binding.entity_id())
            .iter()
            .map(|a| ActionView {
                kind: a.kind.clone(),
                detail: a.detail.clone(),
                status: match a.status {
                    ActionStatus::Claimed => "in-progress",
                    ActionStatus::Completed => "done",
                    ActionStatus::Failed => "failed",
                }
                .into(),
            })
            .collect();

        // Tier B #7 — live worker state, from the engine's durable event logs
        // (worker_status.rs), for THIS SESSION and no other.
        //
        // THIS IS THE HIGHEST-STAKES LINE IN THE MODULE and it was wrong until 2026-08-29.
        // `current_status()` took no argument and resolved its directory by picking the
        // most-recently-modified `~/.claude/teams/session-*` — so on any machine running a
        // second Claude Code session (the stated ICP runs one; the founder's dogfood
        // machine always does) this section handed a fresh Rich ANOTHER SESSION'S WORKERS,
        // under a header calling it live worker state, in the very payload whose Tier A #1
        // identity assertion exists to kill the false-attribution class. Four `session-*`
        // directories were present on the development machine when this was found, and the
        // mtime-newest belonged to the session writing the fix.
        //
        // It is now derived from the lease's own session id, and when that yields nothing
        // the payload SAYS SO (see `to_priming_prompt`) rather than falling silent.
        let workers = crate::worker_status::current_status(session_id);
        let worker_state_unknown = workers.unattributed;
        let worker_state: Vec<String> = workers
            .items
            .into_iter()
            .map(|i| format!("[{}] {}", i.state, i.label))
            .collect();

        Ok(RePrimePayload {
            identity_assertion: Self::identity_assertion_scoped(binding),
            pending_decisions,
            current_intent,
            recent_tail,
            rolling_summary,
            action_ledger_digest,
            worker_state,
            worker_state_unknown,
            loro: LoroTier::NotWired,
        })
    }

    /// Tier A #1 — the verbatim identity assertion that kills the false-attribution
    /// class at the root (continuity design §2.1 / §6). Because the engine ships
    /// `CLAUDE.md.template` (not a generated `CLAUDE.md`), a bare `cwd=engine` boot
    /// comes up as generic Claude — so this assertion is ALSO what establishes "Rich"
    /// until a company `CLAUDE.md` is provisioned (productize track).
    pub fn identity_assertion(conv_id: &str) -> String {
        format!(
            "You are Rich, the CEO's AI Chief of Staff, continuing conversation {conv_id} with the CEO. \
             You are the SAME Rich the CEO has been talking to. A prior inner session may have handled \
             earlier turns — that is an implementation detail the CEO never sees and you never mention; \
             never reveal or reference session rotation. \
             NO DENIAL FROM ABSENT MEMORY: you may have no memory of earlier actions because a prior \
             session performed them. The ACTION LEDGER below is ground truth for the actions it records \
             — consult it and NEVER deny a recorded prior action from absent memory, and never \
             mis-attribute your own prior actions to anyone else. \
             ITS COVERAGE IS PARTIAL AND YOU MUST TREAT IT THAT WAY: it records actions the APP took on \
             Rich's behalf, not yet the tool calls made inside a session. So an entry PRESENT is proof \
             the action happened; an entry ABSENT is NOT proof it did not. Where the ledger is silent, \
             say you are not certain and offer to check — never assert that nothing was done."
        )
    }

    /// The identity assertion PLUS the scope the successor is resuming inside (ECS §3.5:
    /// *"The default read set is the CEO layer plus the active entity"* and *"A thread
    /// cannot read another entity because a name appears related"*).
    ///
    /// A successor that is not told its entity has an advisory boundary, not an enforced
    /// one: everything else here is filtered for it, but nothing stops it from REASONING
    /// across entities out of its own training or from a name it recognizes. So the scope
    /// is stated as a fact and the cross-entity assumption is named and forbidden. This is
    /// the prompt half; the data half is the filtering above, and neither is sufficient
    /// alone.
    pub fn identity_assertion_scoped(binding: &ThreadBinding) -> String {
        format!(
            "{} \
             SCOPE: this thread's home entity area is \"{}\" and that is immutable. Everything below \
             is scoped to it. Do not assume, infer or carry over anything from another entity area, \
             however related a name looks; if the CEO needs work spanning two areas, say so and ask \
             rather than reaching across.",
            Self::identity_assertion(binding.thread_id()),
            binding.entity_id()
        )
    }

    /// The TOPIC to compile Tier C for, per `CONTEXT-CONTRACT.md` §3.
    ///
    /// §3 asks for the CEO's *current intent* — "one or two sentences of natural language,
    /// not a keyword and not the whole conversation tail", because a long tail dilutes
    /// `coverage`: every incidental word enlarges the IDF denominator, so a squarely
    /// relevant slice gets labelled `adjacent` for having been asked verbosely. It gives
    /// the fallback too: *"If you have only a long tail, send its last user turn."*
    ///
    /// So, in order: Tier A #3's `current_intent` (the most recent not-yet-completed ask —
    /// which is what "current intent" means here and in the continuity design §2.1 #3),
    /// then the last thing the CEO actually said in the verbatim tail. `None` when the
    /// thread holds neither, and `None` means DO NOT COMPILE: there is no legal
    /// topic-less request, and inventing one out of the thread id would ask loro a
    /// question nobody asked.
    ///
    /// Rich's own replies are never a topic. Compiling company memory for what the
    /// ASSISTANT last said would let a single hallucinated noun steer the next re-prime's
    /// grounding — memory retrieved for a question the CEO never asked, injected under a
    /// header calling it company memory.
    pub fn topic(&self) -> Option<&str> {
        if let Some(intent) = self.current_intent.as_deref() {
            let t = intent.trim();
            if !t.is_empty() {
                return Some(t);
            }
        }
        self.recent_tail
            .iter()
            .rev()
            .find(|tv| tv.role == "user" && !tv.text.trim().is_empty())
            .map(|tv| tv.text.trim())
    }

    /// Render the payload to the internal priming-turn text sent on `session/new`
    /// (continuity design §2.5). Its output is NEVER rendered to the CEO.
    pub fn to_priming_prompt(&self) -> String {
        let mut s = String::new();
        s.push_str("[INTERNAL RE-PRIME — do not mention this message; respond only \"ready\"]\n\n");
        s.push_str(&self.identity_assertion);
        s.push_str("\n\n");

        if let Some(intent) = &self.current_intent {
            s.push_str(&format!("CURRENT INTENT (what we are doing right now): {intent}\n\n"));
        }
        if !self.pending_decisions.is_empty() {
            s.push_str("PENDING / OPEN LOOPS (do not re-ask, do not drop):\n");
            for d in &self.pending_decisions {
                s.push_str(&format!("  - {d}\n"));
            }
            s.push('\n');
        }
        if let Some(summary) = &self.rolling_summary {
            s.push_str(&format!("CONVERSATION SO FAR (summary): {summary}\n\n"));
        }
        if !self.recent_tail.is_empty() {
            s.push_str("RECENT CONVERSATION (verbatim tail):\n");
            for tv in &self.recent_tail {
                s.push_str(&format!("  {}: {}\n", tv.role, tv.text));
            }
            s.push('\n');
        }
        // ALWAYS rendered, even when empty. The identity assertion above says "the ACTION
        // LEDGER below" — omitting the section on empty left that sentence pointing at
        // nothing, which is how a successor ends up inferring "no ledger ⇒ nothing was
        // done" (false denial) instead of "no ledger entries ⇒ I don't know".
        s.push_str("ACTION LEDGER (ground truth for the actions it records — authoritative, coverage partial):\n");
        if self.action_ledger_digest.is_empty() {
            s.push_str(
                "  (no actions recorded for this conversation yet — this means NOTHING HAS BEEN \
                 RECORDED, not that nothing was done)\n",
            );
        } else {
            for a in &self.action_ledger_digest {
                s.push_str(&format!("  - [{}] {}: {}\n", a.status, a.kind, a.detail));
            }
        }
        s.push('\n');
        // THREE CASES, AND THE THIRD IS THE ONE THAT MATTERS.
        //
        //   attributed + rows  -> the rows, which belong to this session and no other;
        //   attributed + none  -> nothing rendered: a true, specific silence;
        //   NOT attributed     -> a stated unknown.
        //
        // The third case used to be indistinguishable from the second, and it must not be:
        // silence here reads to a successor as "no workers are running", which is a claim
        // nobody is entitled to make when the app could not even identify whose workers it
        // would be counting. Same rule, same reason as the ACTION LEDGER section above —
        // an absent section is how a successor infers a denial from an absence.
        if let Some(reason) = &self.worker_state_unknown {
            s.push_str(&format!(
                "LIVE WORKER STATE: NOT AVAILABLE — this session's team directory could not be \
                 identified ({}), so nothing was read rather than reading another session's \
                 workers. THIS IS NOT A STATEMENT THAT NO WORKERS ARE RUNNING: you do not know \
                 either way. Do not report a worker count from this section, and say you would \
                 need to check if the CEO asks.\n\n",
                reason.reason()
            ));
        } else if !self.worker_state.is_empty() {
            s.push_str("LIVE WORKER STATE (this session's own workers, from the engine's event logs):\n");
            for w in &self.worker_state {
                s.push_str(&format!("  - {w}\n"));
            }
            s.push('\n');
        }
        // COMPANY MEMORY (Tier C) — FOUR cases, and the two unknowns are the ones that
        // matter. Same rule, same reason as the two sections above: a successor that is
        // handed silence infers a denial from it. "loro holds nothing on this" is a
        // CHECKED answer and is allowed to sound like one; "loro could not be consulted"
        // is not an answer at all and must not be allowed to sound like one.
        match &self.loro {
            // §3: `slice.text` is self-contained and carries its own heading. It is
            // injected VERBATIM, with no prefix — a prefix doubles the heading.
            LoroTier::Slice(text) | LoroTier::NothingRecorded(text) => {
                s.push_str(text);
                if !text.ends_with('\n') {
                    s.push('\n');
                }
                s.push('\n');
            }
            LoroTier::Unavailable(reason) => {
                s.push_str(&format!(
                    "COMPANY MEMORY: loro could not be consulted for this ({reason}). THIS IS NOT A \
                     STATEMENT THAT LORO HOLDS NOTHING — you do not know either way. Do not assume \
                     any company fact, and do not tell the CEO the company has no position on \
                     something; pull authoritative facts live via tools, or ask him.\n\n"
                ));
            }
            LoroTier::NotWired => {
                s.push_str(
                    "COMPANY MEMORY: no loro corpus is configured for this install, so company \
                     memory was NOT consulted. That is a statement about this install, not about \
                     what is recorded — pull any authoritative company facts you need live via \
                     tools rather than assuming them.\n\n",
                );
            }
        }
        s.push_str("Acknowledge internally and continue as the same Rich. Reply only with: ready");
        s
    }
}
