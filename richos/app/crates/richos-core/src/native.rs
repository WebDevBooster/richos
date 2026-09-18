//! The NATIVE CLIENT — RichOS drives the `claude` binary directly over stream-json stdio.
//!
//! **This file replaces `acp.rs`.** CEO ruling 2026-08-31, `wiki/ceo-decisions.md` §16:
//! *"the adapter goes"*. RichOS is Claude; the ACP adapter's whole value was portability to
//! backends this product has declined, and it cost 112 resolved npm packages across ~99
//! publishers that the CEO's own Developer ID would have vouched for.
//!
//! Same transport SHAPE as the file it replaces — newline-delimited JSON over a child's
//! stdio, one reader thread, an mpsc into the turn loop, one auto-approve seam — with a
//! different message vocabulary. The wire was captured before a line of this was written:
//! `docs/verification/native-claude-stream-json-2026-08-31/` (twelve runs, raw JSONL
//! committed unedited) and `docs/verification/native-claude-tool-status-2026-08-31/`.
//!
//! ```text
//!   spawn: claude --print --input-format=stream-json --output-format=stream-json
//!                 --include-partial-messages --verbose --setting-sources ''
//!                 --no-session-persistence --session-id <ours>
//!                 --permission-prompt-tool stdio
//!   control_request{initialize}          -> control_response{success}          [handshake]
//!   {"type":"user","message":{...}}      -> stream_event/assistant/user/... frames
//!                                        -> result {stop_reason, terminal_reason, usage}
//!   control_request{can_use_tool}        <- the agent asks; we answer (the seam, below)
//!   control_request{interrupt}           -> control_response, then a result
//! ```
//!
//! Auth = the customer's own `claude` login. No `ANTHROPIC_API_KEY`: every spike run had it
//! removed from the environment (`env -u`) and the binary reported `apiKeySource: "none"`
//! and completed real turns on subscription OAuth.
//!
//! ## THE LICENCE CONDITION THIS FILE IS BUILT AROUND
//! **RichOS may never collect, store, or intermediate Claude credentials or session
//! tokens.** The customer signs in to the unmodified binary with their own subscription and
//! Anthropic bills them directly. This is a condition of the licence that permits RichOS to
//! exist in this shape (`docs/research/claude-code-redistribution-2026-08-31.md`;
//! `ceo-decisions.md` §16).
//!
//! Concretely, and these are design decisions rather than good intentions:
//!
//! - Nothing here reads the keychain, and nothing here sets or forwards an API key.
//! - The `initialize` handshake's reply carries an `account` object (email, organization,
//!   `subscriptionType`). [`NativeClient::handshake`] reads it for **liveness only** — it
//!   checks that a `success` came back and keeps NOTHING. It is not normalized into
//!   machinery, not logged, and not returned to any caller.
//! - So there is no login-status indicator, because the obvious way to build one would
//!   breach the condition. That is a named absence, not an oversight.
//!
//! ## THE UNDOCUMENTED FLAG, AND WHY THIS FILE CANNOT DEGRADE QUIETLY
//! `--permission-prompt-tool stdio` is what arms the `can_use_tool` channel, and it **does
//! not appear in `claude --help`** — re-verified 2026-08-31 against version **2.1.252**:
//! 274 lines of help, zero matches. The binary also self-updates: four versions sit in
//! `~/.local/share/claude/versions/` on this machine (2.1.246, 2.1.250, 2.1.251, 2.1.252),
//! and the 2026-08-31 spike ran against 2.1.251 — it moved WHILE this was being built.
//!
//! §16 accepted that risk and recorded the mitigation: a custom launcher at
//! `~/.local/bin/claude` survives auto-update, so the flag can be pinned without modifying
//! any binary (which also keeps the "must not be modified" licence condition intact).
//! [`resolve_claude_bin`] prefers that path for exactly this reason.
//!
//! **What this file guarantees, and it is the whole of the guarantee:**
//!
//! - The flag is in [`child_args`] unconditionally. There is no code path that drops it and
//!   continues, no env override that disables it, and no fallback client. `args_always_carry_the_permission_flag`
//!   pins that.
//! - A binary that REJECTS the flag is caught at [`NativeClient::spawn`], loudly, before any
//!   turn: an unknown option makes `claude` write `error: unknown option '<flag>'` to stderr
//!   and **exit 1 with zero bytes of stdout** (measured 2026-08-31 on 2.1.252, both for a
//!   nonsense flag and alongside a good one). The handshake turns that into
//!   [`NativeError::Startup`], carrying the child's own stderr verbatim.
//! - A missing binary is [`NativeError::BinaryMissing`], before a process is spawned — and
//!   ONLY a missing binary. A missing engine directory is [`NativeError::WorkingDirMissing`]
//!   and an unrunnable one is [`NativeError::BinaryNotExecutable`], because `ENOENT` from
//!   `Command::spawn` means either of the first two and reporting one as the other sends
//!   whoever set RichOS up looking in the wrong place. `preflight` separates them before a
//!   process exists.
//! - A binary that starts but never answers the handshake is [`NativeError::Startup`] after
//!   [`HANDSHAKE_TIMEOUT`], never an indefinite hang.
//!
//! **What it does NOT guarantee, stated plainly rather than left to be discovered.** If the
//! flag is one day still ACCEPTED but silently stops arming the channel, nothing here
//! detects it at startup: the handshake would pass and the failure would surface only as a
//! tool that never runs. The `initialize` reply carries no field naming the permission
//! prompt tool (checked — 17 fields, none of them it), so there is nothing to assert
//! against. That is **unproven** and it is not fixable from this side.

use crate::cognition::{Cognition, CognitionError, TurnItem};
use crate::machinery::MachineryRecord;
use crate::steering::TurnCancel;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

/// The undocumented flag the whole `can_use_tool` channel hangs off (§16).
///
/// A named constant because it is the single most fragile dependency in this file, and a
/// grep for it must find every place it matters: the arg vector, the test that pins it, and
/// this doc.
pub const PERMISSION_PROMPT_TOOL: &str = "--permission-prompt-tool";

/// The flag that carries RichOS's standing instruction into the child (`doctrine.rs`).
///
/// **The SECOND semi-documented flag this file hangs off, and it is in the same fragility
/// class as [`PERMISSION_PROMPT_TOOL`] for a slightly different reason.** It is not its own
/// entry in `claude --help`; it appears only inside `--bare`'s description (help line 52 on
/// 2.1.263). It was proven real with a positive control, because a first test gave a false
/// green — `claude --anything --help` exits 0, so `--help` proves nothing about a flag:
///
/// ```text
/// $ claude --append-system-prompt-file /etc/hosts --definitely-not-a-flag --print x 2>&1 | head -1
/// error: unknown option '--definitely-not-a-flag'      # so the -file flag IS known
/// $ claude --append-system-prompt-file /nonexistent/zzz.md --print x ; echo $?
/// Error: Append system prompt file not found: /nonexistent/zzz.md
/// 1
/// ```
///
/// The same three defenses as the permission flag, written the same way on purpose:
///
/// - it is in [`chat_child_args`] unconditionally — no environment override, no fallback path,
///   pinned by `chat_args_always_carry_the_doctrine_flag`;
/// - a binary that REJECTS it is caught at [`NativeClient::spawn`] (exit 1, zero bytes of
///   stdout, the child's own stderr in [`NativeError::Startup`]), and a MISSING file is caught
///   even earlier by [`preflight`], which names the path;
/// - a binary that accepts it and silently stops honoring it is the case nothing structural can
///   catch. That is what the behavioral sentinel is for, and why the sentinel is a release gate
///   rather than a one-off — see `tests/doctrine_sentinel.rs`.
pub const APPEND_SYSTEM_PROMPT_FILE: &str = "--append-system-prompt-file";

/// The flag that carries RichOS's own SKILLS into the child (`skills.rs`).
///
/// Unlike the two flags above this one is fully documented (`--plugin-dir <path>`, "Load a
/// plugin from a directory or .zip for this session only"), and `--bare`'s own help names it
/// among the ways to *"explicitly provide context"*. So the fragility here is not the flag.
///
/// **The fragility is that it fails SILENTLY, and that is measured.** A `--plugin-dir` naming a
/// path that does not exist produces exit 0, a clean handshake, `plugins: []` and a perfectly
/// ordinary turn — `docs/verification/inner-doctrine-skills-2026-09-06/`, cell K4. That is the
/// exact quiet degradation `--append-system-prompt-file` was chosen for NOT doing. So the
/// loudness is built rather than inherited, in two layers:
///
/// - [`preflight`] proves the manifest and every declared `SKILL.md` are present and non-empty
///   before a process exists, and raises [`NativeError::SkillsMissing`] naming the file;
/// - the reader thread reads the first `system/init` frame's `plugins` array and records
///   [`skills::SkillsVerdict`], so a directory the BINARY declined is a positive signal rather
///   than an absence somebody has to notice. The module doc above records that no such field
///   exists for [`PERMISSION_PROMPT_TOOL`]; for this one it does, and it is used.
pub const PLUGIN_DIR: &str = "--plugin-dir";

/// The environment variable that decides whether the child DEFERS its own tools, and the
/// value that stops it deferring them on the conversation.
///
/// **This is the third undocumented dependency in this file, and it is here because a
/// deferred register costs the CEO two round trips before he hears a word.** Measured on the
/// shipped path, `docs/verification/question-receipt-2026-09-18.md` run 2, one question turn:
///
/// ```text
///       3.934 s  ToolSearch                                        <- discovering the register
///       3.940 s  select:mcp__richos_assignments__record
///       4.999 s  tool_call
///       7.593 s  ToolSearch                                        <- discovering the continuity tools
///       7.653 s  select:mcp__richos_continuity__checkpoint,…
///      11.027 s  tool_call
///      17.982 s  mcp__richos_assignments__record                   <- the register, FOURTH
///      22.956 s  his first word
/// ```
///
/// The doctrine has said *"the register is your FIRST tool call"* since the front desk
/// existed, and it cannot be obeyed by a model that has to look the register up first. §55 is
/// *"a few seconds"*; seven of those twenty-three seconds were discovery.
///
/// **Why an environment variable and not a flag: there is no flag.** Re-derived from the
/// shipped binary rather than from documentation — `claude` 2.1.275, the module that decides
/// it (`chunk-gxmxm8v7`/`chunk-fp50hwzg` region at byte offset 173_562_000):
///
/// ```text
/// function EYe(){ if(f_t())return"standard"; if(u())return"tst";
///   let e=process.env.ENABLE_TOOL_SEARCH, r=e?UQn(e):null;
///   if(r===0)return"tst"; if(r===100)return"standard";
///   if(m(e))return"tst-auto"; if(Oe(e))return"tst"; if(To(e))return"standard";
///   return"tst" }                                   // <- UNSET MEANS DEFERRAL IS ON
/// function To(e){ … return["0","false","no","off"].includes(String(e).toLowerCase().trim()) }
/// function Mg(){ let e=EYe(); if(e==="standard"){ …; return!1 } … }
/// ```
///
/// So `"false"` is one of five spellings `To` accepts, `EYe()` returns `"standard"`, and
/// `Mg()` — the session's one "is tool search on" decision — returns false. The DEFAULT is
/// deferral, which is exactly the third-party default this project refuses to inherit
/// unexamined.
///
/// **Three defenses, the same three the flags above it get:**
///
/// - it is set unconditionally for [`LeaseRole::Conversation`] by [`tool_residency_env`],
///   pinned by `the_conversation_asks_for_resident_tools`;
/// - an unknown variable cannot fail a spawn, so the loudness is built rather than inherited:
///   the reader reads `ToolSearch` out of the child's own init inventory into
///   `ReaderState::tool_search_offered` and says so on stderr. A knob that is renamed, or a
///   binary that starts deferring for a different reason, shows up as the tool being offered
///   again;
/// - and the number itself is re-measured end to end by
///   `examples/first_reply_timing_e2e.rs`, which refuses a turn whose first tool call is not
///   the register.
///
/// **Not set on the work lease, deliberately.** Nobody is sitting in front of a work lease's
/// first token, its inventory is a different size, and one measurement on one lease is not
/// evidence about the other. Changing both on the strength of the front desk's numbers would
/// be scope this measurement does not cover.
pub const TOOL_SEARCH_ENV: &str = "ENABLE_TOOL_SEARCH";

/// The value [`TOOL_SEARCH_ENV`] is given. See that constant for the five spellings the
/// binary accepts and why this is one of them.
pub const TOOL_SEARCH_OFF: &str = "false";

/// The name of the child's own tool-discovery tool, as it appears in `system/init.tools`.
pub const TOOL_SEARCH_TOOL: &str = "ToolSearch";

/// The environment a lease is spawned with so its tools are RESIDENT from the first turn —
/// `None` where RichOS has measured nothing and therefore changes nothing.
///
/// A pure function so the pin is a unit test rather than a spawned process, exactly as
/// [`child_args`] is.
pub fn tool_residency_env(role: LeaseRole) -> Option<(&'static str, &'static str)> {
    match role {
        LeaseRole::Conversation => Some((TOOL_SEARCH_ENV, TOOL_SEARCH_OFF)),
        LeaseRole::Work => None,
    }
}

/// **What the app says on stderr when it withheld prose the model added after the receipt.**
///
/// The withheld run is, every time it has been measured, a second copy of the sentence the app has
/// just said — `"On it!On it!"` in the CEO's own conversation, run 1 of
/// `docs/verification/first-reply-2026-09-18.md`. It is withheld rather than shown, and SAID rather
/// than dropped, because a host that silently swallows the model's words is the silent degrade §16
/// forbids: whoever debugs a turn where Rich said something unexpected needs to see that the host
/// took it, and what it was.
pub const WITHHELD_AFTER_THE_RECEIPT: &str =
    "[richos] the register's receipt had already been said, so the model's own words after it were \
     withheld from the conversation";

/// The continuity checkpoint tool — the front desk's own bookkeeping.
pub const CONTINUITY_CHECKPOINT_TOOL: &str = "mcp__richos_continuity__checkpoint";

/// What the child is told when it tries to write the checkpoint before it has said anything.
///
/// **A refusal the CEO never sees, and the only sentence in this file whose whole job is to
/// change what the model does NEXT.** It names the order rather than the rule, because a model
/// that is told "not now" and not "do this instead" pays another round trip working it out.
pub const CHECKPOINT_BEFORE_REPLY: &str =
    "Not yet — he has not heard anything from you on this turn. Answer him first, in as few      words as the situation takes, and write the checkpoint after you have spoken. It is      bookkeeping: it is never worth a second of his waiting.";

/// Is this the front desk trying to do its bookkeeping before it has said a word?
///
/// **The ordering the doctrine states and could not enforce.** `front-desk.md` has asked for
/// the reply first since the front desk existed; run 2 of
/// `docs/verification/question-receipt-2026-09-18.md` measured a `checkpoint` round trip
/// occupying 12.980 s to 17.023 s of a 22.956 s wait, ahead of both the register and his first
/// word. A sentence that is not obeyed is not a fix, so the order is a condition of the tool
/// being usable rather than a request.
///
/// **Scoped to the checkpoint, and `inspect` is deliberately NOT here.** A write is bookkeeping
/// and has nowhere to be before the reply; a read may BE the answer he is waiting for (the
/// doctrine's case 1, "you know the answer"), and refusing it would make a fast answer
/// impossible in the name of making a reply fast. The work lease is not reached by this at all
/// — it is never given the continuity server (§5.8a-ii seam 1).
///
/// # MEASURED 2026-09-18: THIS GATE DOES NOT FIRE ON THE REAL WIRE. Read this before trusting it.
///
/// The paragraphs above describe it as the enforcement the doctrine sentence could not be. **It is
/// not, in production, and the measurement is
/// `docs/verification/first-words-2026-09-18-logs/run-B-the-pre-reply-checkpoint-is-not-refused-on-the-real-wire.log`.**
/// On both turns of that run the model wrote the checkpoint BEFORE it said anything (8.932 s and
/// 5.429 s), the ECS write succeeded, and his first words arrived at 15.714 s and 12.176 s against
/// 7.998 s and 6.358 s on the same code with no pre-reply checkpoint (run A).
///
/// **Why:** this function is reachable only from a `can_use_tool` control request
/// ([`NativeClient::handle_agent_request`]), and **no permission frame appears anywhere in that
/// run** — the probe traces every one it is handed. The lease is spawned with
/// `--permission-mode auto` and the `autoMode` settings block (`engine_profile.rs:214-222`), under
/// which the binary classifies and auto-approves its own trusted MCP tools and never asks the
/// app's desk about them. The desk sees `Bash` and the things auto mode will not take by itself;
/// it does not see `mcp__richos_continuity__checkpoint`.
///
/// **What IS enforceable, and why neither half is taken here.** The engine's own adapter gates both
/// continuity tools on the app-written `actions_allowed` flag and re-reads the scope file on every
/// call (`engine/ecs/adapters/mcp.py:18-26`), so the app could refuse a pre-reply checkpoint by
/// deferring that grant until it has spoken — with no engine change, but it would close `inspect`
/// before the reply too, which this function's own paragraph above deliberately keeps open.
/// Gating `checkpoint` alone needs a field in that scope and a change in the adapter, which is an
/// engine release. **Which of the two is a design call about what the front desk may do before it
/// speaks, so it is raised rather than taken:** `esc-20260918T141320Z-49570979`.
///
/// The function stays, tests and all: it is correct, it is cheap, and a build or a permission mode
/// that does ask the desk gets the ordering it describes. What it must not be is quoted as the
/// reason the pre-reply checkpoint cannot happen. It can, and it was measured happening.
fn bookkeeping_before_the_reply(request: &Value, spoken: bool) -> bool {
    !spoken && request.get("tool_name").and_then(|v| v.as_str()) == Some(CONTINUITY_CHECKPOINT_TOOL)
}

/// Is the child deferring its tools, according to the child?
///
/// The one reading that can catch [`TOOL_SEARCH_ENV`] silently stopping work. Its own tool is
/// in the inventory exactly when discovery is live, so this is a fact from the wire and not an
/// inference from the variable having been set.
///
/// **And the MCP tools being listed proves nothing about this**, which is the trap worth
/// naming: `assignment_tool_loaded`, `status_tool_loaded` and `continuity_tools_loaded` were
/// all `true` on the run whose model still had to `ToolSearch` for the register
/// (`docs/verification/question-receipt-2026-09-18.md`). A deferred tool is still in the init
/// inventory. Only the presence of the discovery tool separates the two.
fn tool_search_from_init(init: &Value) -> InitFact {
    InitFact::reported(
        init["tools"].as_array().is_some_and(|tools| tools.iter().any(|tool| tool.as_str() == Some(TOOL_SEARCH_TOOL))),
    )
}

/// How long [`NativeClient::spawn`] waits for the `initialize` handshake before refusing.
///
/// **Measured, not guessed:** the handshake answered in **697.9 ms** on 2.1.252 with the
/// full production arg vector (2026-08-31, `ANTHROPIC_API_KEY` removed), and the spike's
/// Rust run measured it at the same order (`run9-rust-driven.timings.tsv`: the
/// `control_response` line was read at offset **0.598 s**). 30 s is 43x the measured figure —
/// wide enough that a cold start on a slow disk is never cut off, and short enough that a
/// binary which will never answer is refused while the CEO is still looking at the splash
/// rather than at a frozen window.
pub const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(30);

/// The `stop_reason` `prompt` returns when the agent acknowledged the cancel.
///
/// **This is OURS on this wire, and that is a real change from the file this replaces.**
/// ACP answered a cancelled prompt with `stopReason: "cancelled"`. The native binary answers
/// with `stop_reason: null`, `subtype: "error_during_execution"`, `is_error: true` and
/// `terminal_reason: "aborted_streaming"` (`raw/run9-rust-driven.jsonl:65`) — the fact
/// survives, it just lives on a different field. [`stop_reason_of`] maps it back, so
/// everything downstream (`spine.rs`, `steering.rs`, the ledger) keeps the one string it
/// already reasons about.
pub const STOP_REASON_CANCELLED: &str = "cancelled";

/// **Which of the two leases this is** — the background-work spec §2.1's second connection,
/// made a type rather than a boolean so every place that has to care says which one it
/// means.
///
/// The two differ in what the CHILD is given, not in how the host holds it:
///
/// | | `Conversation` | `Work` |
/// |---|---|---|
/// | `richos_continuity` in its MCP config | yes | **no** — spec §5.8a-ii seam 1 |
/// | continuity tools required to start a turn | yes (`:1960-1962`) | no, because it was not given them |
/// | its preparation calls `bridge.brief` | yes (`:1972`) | **no** — seam 2 |
/// | `richos_onboarding` in its MCP config | yes | **no** — since 2026-09-18; Ray's candidate-.8 row 1 |
/// | an action grant over a company scope | yes | **no** — nothing writes a work lease one |
/// | ECS seat | the CEO's | its own, one per assignment (§5.8c) |
/// | audience | `ceo` | `worker` |
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LeaseRole {
    Conversation,
    Work,
}

/// The three role decisions, as functions, **because the call sites use these and the tests
/// assert on these.** A test that re-stated the condition would be a second copy of the
/// rule that agrees with the first only until somebody edits one of them — which is the
/// shape of a negative test that passes for its own reasons.
///
/// Seam 2 of the background-work spec §5.8a-ii: a work lease must not come down
/// `prepare_work_turn`'s path, because that path calls `bridge.brief` and the brief is the
/// CEO's.
fn work_preparation_refusal(role: LeaseRole) -> Option<&'static str> {
    (role == LeaseRole::Work).then_some("A background work connection does not take conversation turns.")
}

/// And the other way round: a conversation lease does not take background assignments.
fn assignment_binding_refusal(role: LeaseRole) -> Option<&'static str> {
    (role == LeaseRole::Conversation)
        .then_some("The conversation's connection does not take background assignments.")
}

/// Spec §5.8a-ii's stated consequence of seam 1: the readiness assertion is about what
/// THIS lease was configured with. A work lease was deliberately not given the continuity
/// tools, so a lease-blind check would refuse its turn and it would never start.
fn requires_continuity_tools(role: LeaseRole) -> bool {
    role == LeaseRole::Conversation
}

/// The same rule, for the tools the CEO's Two Riches page moved.
///
/// **`richos_work` is now the WORK lease's and only the work lease's**, so the readiness
/// assertion that used to hold for every lease with an engine profile has to ask which
/// lease it is standing on — otherwise the conversation refuses its own turn for not
/// having a tool it is deliberately no longer given. Same shape as
/// [`requires_continuity_tools`], opposite side.
fn requires_work_tools(role: LeaseRole) -> bool {
    role == LeaseRole::Work
}

/// And the front desk's read (`status_tools.rs`). Asserted for the same reason the
/// `--plugin-dir` verdict is: once the work tools are off this lease, this is the ONLY way
/// the front desk can see what is running, and a status server that silently failed to
/// connect would produce a Rich who answers "nothing is running" because he cannot look.
fn requires_status_tool(role: LeaseRole) -> bool {
    role == LeaseRole::Conversation
}


/// What the child's own `system/init` frame said about ONE readiness fact.
///
/// **Three states, because the init frame arrives with the first TURN and not with the
/// handshake** ([`child_args`]'s doc says so, and the `initialize` control handshake reads a
/// `subtype` and keeps nothing else). So for the whole of a lease that has never been used,
/// the truthful answer to "did the engine plugin load" is *nobody has told us* — which is
/// not the same statement as *we were told no*, and calls for the opposite response.
///
/// Deliberately the same shape, and the same argument, as [`crate::skills::SkillsVerdict`]:
/// *"'we have not been told yet' and 'we were told it is not there' call for opposite
/// responses, and collapsing them is how an absence gets reported as a fact."*
///
/// **These three facts were plain `bool`s until 2026-09-18, and the collapse cost the
/// product every background job it had.** `bind_work_assignment` runs before the work
/// lease's first turn, so it read `false`, called it a refusal, and failed the assignment
/// with *"The desktop engine plugin did not load"* — on a lease whose plugin had in fact
/// loaded and whose `SessionStart` hook had already written evidence proving it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InitFact {
    /// No `system/init` frame has arrived on this lease yet. Never a refusal on a path that
    /// runs before the first turn; always one on a path that runs after it.
    NotYetReported,
    /// The frame arrived and the fact holds.
    Yes,
    /// The frame arrived and the fact does not hold. **This is the loud case**, and it is
    /// the one every sentence in this file was written for: `--plugin-dir` accepts a path it
    /// cannot use and reports success (measured, `inner-doctrine-skills-2026-09-06/` cell
    /// K4), so a reported absence is the only thing that catches it.
    No,
}

impl InitFact {
    /// Read a fact off a frame that HAS arrived. There is no constructor for
    /// [`Self::NotYetReported`] on purpose: it is a default, never a reading.
    fn reported(holds: bool) -> Self {
        if holds { Self::Yes } else { Self::No }
    }
}

/// The three init-reported facts a background assignment depends on, each paired with the
/// sentence its absence is reported by — named ONCE so the two places that ask about them
/// cannot drift into disagreeing about which fact carries which sentence.
fn work_readiness_facts(state: &ReaderState) -> [(InitFact, &'static str); 3] {
    [
        (state.engine_plugin_loaded, ENGINE_PLUGIN_ABSENT),
        (state.work_tools_loaded, WORK_TOOLS_ABSENT),
        (state.automatic_permissions, AUTOMATIC_PERMISSIONS_ABSENT),
    ]
}

pub(crate) const ENGINE_PLUGIN_ABSENT: &str = "The desktop engine plugin did not load";
pub(crate) const WORK_TOOLS_ABSENT: &str = "The desktop work tools did not load";
pub(crate) const AUTOMATIC_PERMISSIONS_ABSENT: &str = "The provider did not enable automatic permission checks. Update or reconnect a supported provider account before starting app work; no bypass mode was enabled.";

/// The gate at the BINDING, which runs before the work lease's first turn.
///
/// **Only a REPORTED absence refuses.** An unreported fact is not evidence of anything, and
/// treating it as a refusal here is the whole of the 2026-09-18 defect: every background job
/// this build was ever given failed at this gate, 6.545 s and 7.486 s after registration,
/// before its lease had run a single turn.
///
/// The loudness is not softened, it is MOVED to where the fact exists —
/// [`work_turn_readiness_refusal`], asked on the same lease against the same three facts
/// with the same three sentences, once its first turn has brought the frame that answers
/// them. A plugin that really did not load still fails the job and still says so.
fn work_binding_readiness_refusal(facts: [(InitFact, &'static str); 3]) -> Option<&'static str> {
    facts.into_iter().find(|(fact, _)| *fact == InitFact::No).map(|(_, sentence)| sentence)
}

/// The same three facts, asked AFTER the work lease's turn — where anything short of a
/// reported `Yes` is a refusal.
///
/// [`InitFact::NotYetReported`] is a refusal on this path and not on the other one, and the
/// asymmetry is the single fact this whole module records: the frame that answers these
/// questions arrives with the first turn. Before that turn, silence is expected; after it,
/// silence means the frame never came, which is its own fault and not a reason to proceed.
fn work_turn_readiness_refusal(facts: [(InitFact, &'static str); 3]) -> Option<&'static str> {
    facts.into_iter().find(|(fact, _)| *fact != InitFact::Yes).map(|(_, sentence)| sentence)
}

/// The stop reason `prompt` returns when the agent did NOT answer the stopped turn within
/// [`CANCEL_GRACE_MS`] of being told to.
///
/// A distinct string because it is a distinct fact: the CEO's stop still stands and the
/// turn is still recorded as stopped, but this lease is no longer known to be idle, so the
/// spine rotates it at the boundary rather than handing it the next turn (`spine.rs`).
pub const STOP_REASON_CANCEL_UNACKNOWLEDGED: &str = "cancel_unacknowledged";

/// The `terminal_reason` the binary sets on a turn the client interrupted.
pub const TERMINAL_REASON_ABORTED: &str = "aborted_streaming";

/// How long `prompt` waits for the agent to answer the cancelled turn.
///
/// **`acp.rs:49` asked whoever ran the first live stop to replace this bound with a measured
/// figure and to say so. That measurement now exists, and the bound is kept anyway.**
///
/// Measured on this wire (`run9`, the definitive Rust-driven run): the `interrupt`
/// control_response came back in **0.9 ms** and the terminal `result` in **9.1 ms**. The
/// Python driver measured 10 ms / 20 ms independently (`run5`). Against 3,000 ms that is
/// 3000 ÷ 9.1 ≈ **330x of headroom**, i.e. three orders of magnitude.
///
/// It is not tightened to the measurement, and the reason is arithmetic rather than
/// caution: 9.1 ms was an idle model mid-sentence. A cancel that lands while a 30-second
/// `Bash` tool is running has to wait for the agent to finish unwinding it, and
/// `native-claude-tool-status-2026-08-31` measured a **30.002 s heartbeat cadence**, i.e.
/// tools that genuinely run for tens of seconds. A bound tuned to 9.1 ms would report
/// `cancel_unacknowledged` — and force a rotation — on a perfectly healthy agent. 3,000 ms
/// costs the CEO nothing either way: the stop is durable and the UI has already moved to
/// `stopping` before this timer starts.
pub const CANCEL_GRACE_MS: u64 = 3_000;

/// [`CANCEL_GRACE_MS`], overridable by `RICHOS_CANCEL_GRACE_MS`.
///
/// The override exists so the non-compliant-agent test can prove the timeout in
/// milliseconds instead of adding three seconds to every run — and so the bound can be
/// tuned in front of a live binary without a rebuild.
pub fn cancel_grace() -> Duration {
    let ms = std::env::var("RICHOS_CANCEL_GRACE_MS").ok().and_then(|v| v.parse::<u64>().ok()).unwrap_or(CANCEL_GRACE_MS);
    Duration::from_millis(ms)
}

/// How many stderr lines are kept so a startup failure can quote the child's own words.
///
/// Bounded because a long-lived child writes diagnostics forever and an unbounded buffer
/// behind a `Mutex` is a slow leak. The failure this exists for is one line long
/// (`error: unknown option '--permission-prompt-tool'`), so 64 is ~64x what it needs.
const STDERR_TAIL_LINES: usize = 64;

#[derive(Debug, thiserror::Error)]
pub enum NativeError {
    #[error("claude io: {0}")]
    Io(#[from] std::io::Error),
    #[error("claude json: {0}")]
    Json(#[from] serde_json::Error),
    #[error("claude channel closed (child exited?)")]
    Closed,
    #[error("claude protocol error: {0}")]
    Protocol(String),
    /// **LOUD, and deliberately not recoverable here.** The `claude` binary is not where we
    /// looked. Raised BEFORE a process is spawned, so the failure names a path rather than
    /// an exit code.
    #[error("the claude binary was not found at {path} — RichOS drives Claude Code directly and cannot run without it")]
    BinaryMissing { path: String },
    /// **LOUD, raised by [`resolve_claude_bin_checked`] before any process exists at all —
    /// the 2026-09-17 candidate-walk fix.** [`resolve_claude_bin`] used to fall through to
    /// the bare name `claude` here, which a caller then handed to a provider whose `PATH`
    /// `engine_profile.rs` had already replaced with [`crate::runtime::EngineRuntime::path`];
    /// a bare name that `PATH` can never resolve. The failure surfaced two layers downstream,
    /// misclassified by `interruption.rs` as [`crate::interruption::InterruptionCause::Transient`]
    /// ("that kind of thing usually clears on its own") — false for a binary that was never
    /// installed. This variant names every place actually looked, the way `setup.rs::find_claude`
    /// already does for the first-run advisory.
    #[error("no `claude` install could be found on this Mac — looked in: {looked} — install Claude Code, or set RICHOS_CLAUDE_BIN to its path")]
    ClaudeNotFound { looked: String },
    /// **LOUD.** The `claude` binary is exactly where we looked and cannot be run: the
    /// execute bit is off, or the path names a directory. A DIFFERENT fault from
    /// [`NativeError::BinaryMissing`] with a different fix, so it is a different variant —
    /// "install Claude Code" is the wrong instruction for a file that is already there.
    #[error("the claude binary at {path} cannot be executed ({why}) — the file is there, so this is a permissions problem, not a missing install")]
    BinaryNotExecutable { path: String, why: String },
    /// **LOUD, and the one this enum used to report as [`NativeError::BinaryMissing`].**
    /// RichOS starts `claude` with the engine directory as its working directory; a working
    /// directory that does not exist fails the spawn with `ENOENT`, which is the SAME errno a
    /// missing binary produces. Raised BEFORE the spawn so the two can never be confused
    /// again. Measured 2026-09-01: a double-clicked `.app` has `cwd = /`, the old default
    /// resolved to `/../engine`, and the CEO was told his present, executable `claude` was
    /// missing.
    #[error("the engine directory {path} does not exist — RichOS runs Claude with that directory as its working directory and cannot start without it (this is NOT a missing claude binary)")]
    WorkingDirMissing { path: String },
    /// **LOUD.** The engine path exists but is a file, a socket, or anything other than a
    /// directory. Its own variant for the same reason as above: `Command::current_dir`
    /// reports it as `ENOTDIR`, and "it isn't there" would be a false statement about a path
    /// the operator can see.
    #[error("the engine directory {path} exists but is not a directory — RichOS cannot use it as a working directory")]
    WorkingDirNotADirectory { path: String },
    /// **LOUD.** The child started but never completed the `initialize` handshake: it
    /// rejected a flag, exited, or went silent. `stderr` is the child's own words, verbatim,
    /// because on a rejected flag that single line IS the diagnosis.
    #[error("claude failed to start ({reason}); the child said: {stderr}")]
    Startup { reason: String, stderr: String },
    /// **LOUD, and the whole reason `--append-system-prompt-file` won over the alternatives.**
    /// RichOS's standing instruction (`doctrine.rs`) is not at the path we are about to hand
    /// the child. Raised BEFORE the spawn, so the failure names the file rather than arriving
    /// as an exit code — and so it can never be a fallback.
    ///
    /// A Claude started without it is not Rich; it is a generic coding assistant wearing the
    /// product's window. Design §3.2: an absent instruction file under the rejected
    /// `--setting-sources project` candidate produces a successful handshake and a subtly wrong
    /// assistant, which is the class this app refuses to ship.
    #[error("RichOS's standing instruction is not at {path} ({why}) — it will not start Claude without it, because a Claude started without it is not Rich")]
    DoctrineMissing { path: String, why: String },
    /// **LOUD, and loud only because we make it so.** A skill RichOS ships is not on disk where
    /// it is about to be handed to the child.
    ///
    /// Its own variant rather than a reuse of [`NativeError::DoctrineMissing`], because the two
    /// have different fixes and — more importantly — different failure physics. A missing
    /// doctrine file is refused by `claude` itself (exit 1, its own stderr). A missing
    /// `--plugin-dir` is accepted in silence: exit 0, clean handshake, `plugins: []`, an
    /// ordinary turn (measured, `inner-doctrine-skills-2026-09-06/` cell K4). This variant is
    /// the whole of the loudness for that path.
    #[error("a skill RichOS ships is not at {path} ({why}) — it will not start Claude with a skill missing, because `--plugin-dir` accepts a path that is not there without saying so")]
    SkillsMissing { path: String, why: String },
}

impl From<NativeError> for CognitionError {
    fn from(e: NativeError) -> Self {
        match e {
            NativeError::Protocol(m) => CognitionError::Protocol(m),
            other => CognitionError::Io(other.to_string()),
        }
    }
}

// ===========================================================================================
// THE PERMISSION SEAM (ceo-decisions.md §1 and §16)
//
// `acp.rs:444-479` auto-approved every `session/request_permission` by picking the first
// `allow*` option. R2 business-action governance is DEFERRED to V2, not abandoned — §16 says
// so in as many words: *"both paths auto-approve and both leave the same seam for the day
// Rich should ask instead."*
//
// So the seam is here, and it is a NAMED, PUBLIC, TESTED function rather than a match arm
// buried in a reader thread, because "somebody can find it" was the requirement. The day
// Rich should ask instead of allowing, this is the one function that changes.
// ===========================================================================================

/// What RichOS answers when the agent asks whether it may use a tool.
#[derive(Debug, Clone, PartialEq)]
pub enum PermissionDecision {
    /// Proceed, with the input the agent proposed (possibly rewritten).
    Allow { updated_input: Value },
    /// Refuse, with a reason the agent shows in its transcript.
    Deny { message: String },
}

impl PermissionDecision {
    /// The word recorded on the machinery record — `"allow"` or `"deny"`.
    pub fn behavior(&self) -> &'static str {
        match self {
            PermissionDecision::Allow { .. } => "allow",
            PermissionDecision::Deny { .. } => "deny",
        }
    }
}

/// Legacy source-test adapter policy. The shipping desktop engine profile uses
/// `permissions::ScopedPermissions` instead: host-scoped onboarding/continuity tools
/// validate their own contracts and other native permission requests require an
/// exact app decision. Hidden preparation and stopped turns remain denied.
/// This compatibility function is not the desktop action/access contract.
pub fn decide_permission(request: &Value) -> PermissionDecision {
    PermissionDecision::Allow { updated_input: request.get("input").cloned().unwrap_or_else(|| json!({})) }
}

/// Map the binary's terminal `result` frame onto the one stop-reason string the rest of the
/// app already reasons about.
///
/// **Spike caveat C1, resolved here and nowhere else.** ACP said `stopReason: "cancelled"`.
/// This wire says `stop_reason: null` + `subtype: "error_during_execution"` +
/// `terminal_reason: "aborted_streaming"`, and ONLY the last of those separates a cancel
/// from a genuine error — an `error_during_execution` with any other `terminal_reason` is a
/// real failure and must not be reported as the CEO's stop.
pub fn stop_reason_of(result: &Value) -> String {
    if result.get("terminal_reason").and_then(|v| v.as_str()) == Some(TERMINAL_REASON_ABORTED) {
        return STOP_REASON_CANCELLED.to_string();
    }
    if let Some(s) = result.get("stop_reason").and_then(|v| v.as_str()) {
        return s.to_string();
    }
    // No `stop_reason` and not an abort. Report the vendor's own subtype rather than
    // inventing `end_turn` — a turn that ended in a way we have no name for must not be
    // recorded as one that ended cleanly.
    result.get("subtype").and_then(|v| v.as_str()).unwrap_or("unknown").to_string()
}

/// The child's argument vector.
///
/// Every flag is here for a stated reason, and the vector is a pure function so a test can
/// assert on it without spawning anything:
///
/// - `--print` + `--input-format=stream-json` + `--output-format=stream-json` — the duplex
///   stdio protocol this whole file speaks.
/// - `--include-partial-messages` — **the clean-output path depends on it.** Without it the
///   assistant's text arrives only on whole-message `assistant` frames and the CEO would see
///   a turn appear all at once at the end. (The reader defends against that anyway; see
///   `text_deltas_since_message_start`.)
/// - `--verbose` — required for stream-json output.
/// - `--setting-sources ''` — the operator's user/project/local settings stay out. RichOS's
///   behaviour must not depend on files it did not write.
/// - `--no-session-persistence` — the durable Rich is the LEDGER; a lease is disposable and
///   must not leave a second, divergent history on disk (`reprime.rs`).
/// - `--session-id <ours>` — **so `session_id()` is known synchronously at spawn.** ACP had
///   a `session/new` request that returned one; this wire announces it on `system/init`,
///   which arrives with the first TURN, and a lease whose id appeared later would leave the
///   rotation records in `ledger.rs` unable to name the lease they are about.
/// - [`PERMISSION_PROMPT_TOOL`] `stdio` — the undocumented one. See the module doc.
pub fn child_args(session_id: &str) -> Vec<String> {
    [
        "--print",
        "--input-format=stream-json",
        "--output-format=stream-json",
        "--include-partial-messages",
        "--verbose",
        "--setting-sources",
        "",
        "--no-session-persistence",
        "--session-id",
        session_id,
        PERMISSION_PROMPT_TOOL,
        "stdio",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

pub fn chat_child_args(session_id: &str, doctrine: &Path, skills: &Path) -> Vec<String> {
    let mut args = child_args(session_id);
    args.push(APPEND_SYSTEM_PROMPT_FILE.to_string());
    args.push(doctrine.display().to_string());
    args.push(PLUGIN_DIR.to_string());
    args.push(skills.display().to_string());
    args
}



/// Streamed items for the active prompt turn.
///
/// Machinery arrives here RAW and un-normalized on purpose. §1.4's feasibility argument for
/// G1 is that `seq` must be assigned at the mpsc DRAIN point (`prompt`'s loop, which is
/// single-threaded) and not at `dispatch` (which runs on the reader thread). A
/// `MachineryRecord` cannot exist without its `seq`, so `dispatch` hands over the wire JSON
/// and `prompt` normalizes it.
enum ChunkMsg {
    /// Assistant-message text — the clean-output path, unchanged.
    Text(String),
    /// Any other frame, verbatim.
    Frame(Value),
    /// A `can_use_tool` we just answered, with the decision we made.
    Permission { request: Value, chosen: String },
    /// The DERIVED context measurement — see [`MachineryRecord::from_context_usage`]. It is
    /// its own arm rather than a frame because it is the only thing on this channel RichOS
    /// computed rather than received, and that distinction must survive to the record.
    Usage { used: u64, size: u64, usage: Value },
    /// The turn's terminal `result` frame.
    Done(Value),
    /// The CEO pressed stop. Sent by [`NativeCancelHandle`] into THIS turn's channel purely
    /// to wake the drain loop, which is otherwise parked in a blocking `recv()`.
    ///
    /// Waking it this way rather than polling is deliberate arithmetic: a poll loop tight
    /// enough to feel immediate (20ms) would wake 50 times a second for the whole turn —
    /// 8_270s x 50 = 413_500 wakeups on §6.2's own `2h 17m 50s` example, every one of them
    /// finding nothing. One send costs one wakeup, at the moment it is needed.
    Cancel,
}

// ===========================================================================================
// THE BETWEEN-TURN LANE (techy-mode design §1.5, gap #1)
//
// `dispatch` delivers to the prompt channel only while `current_prompt` is `Some`. Anything
// the agent emits at session start, or after a turn's `result` has already been returned,
// would otherwise hit NO SINK AT ALL.
//
// It is deliberately NOT a second `Sender`. A channel would need a receiver parked
// somewhere, and there is no drain loop running between turns by definition; the one thing
// that IS guaranteed to happen is that the spine comes back — to start the next turn, or
// because the CEO opened the technical view. So the lane is a BUFFER the reader thread fills
// and the spine drains, and the drain point is where `seq` is assigned, exactly as §1.4's
// feasibility argument requires for the in-turn path.
// ===========================================================================================

/// How many un-drained between-turn items the buffer holds before it starts refusing.
///
/// Sized against measurement, not taste. `run9-rust-driven.jsonl` shows the per-turn
/// repeating traffic on this wire is one `system/init`, one `system/status` and one
/// `rate_limit_event` — three kinds, all of which the SessionMeta slot below collapses to
/// nothing on a repeat. 256 is therefore ~85 turns of un-drained traffic in the shape
/// actually observed, against a drain that happens at every turn boundary and every
/// technical-view open. An overflow is a marker record, never a silent forget — see
/// [`MachineryRecord::between_turn_overflow`].
const BETWEEN_TURN_MAX: usize = 256;

/// One item the reader thread parked because no turn was in flight to route it to.
///
/// Mirrors the routable arms of [`ChunkMsg`] and none of its control arms: `Done` and
/// `Cancel` are statements about a turn, and there is no turn here. `Usage` is absent for a
/// sharper reason — the measurement is derived from a mid-turn `message_delta`, so it cannot
/// arise between turns at all.
enum BetweenItem {
    Frame(Value),
    Permission { request: Value, chosen: String },
}

impl BetweenItem {
    /// The same item as a streamed [`ChunkMsg`], for the case where a turn IS in flight.
    ///
    /// It CLONES rather than moving, and that is the deliberate trade. `Sender::send`
    /// consumes its argument, so a moving conversion would need an inverse to recover the
    /// item when the receiver has already hung up — an inverse whose `_` arm (`Done`,
    /// `Cancel`, `Usage`) is unreachable by construction and would therefore have to invent
    /// a record or panic on the reader thread. One `Value` clone per client-directed request
    /// buys away that whole arm.
    fn to_chunk(&self) -> ChunkMsg {
        match self {
            BetweenItem::Frame(f) => ChunkMsg::Frame(f.clone()),
            BetweenItem::Permission { request, chosen } => {
                ChunkMsg::Permission { request: request.clone(), chosen: chosen.clone() }
            }
        }
    }
}

/// The buffer plus §1.5's `last_session_meta` slot.
#[derive(Default)]
pub(crate) struct BetweenTurn {
    queue: Vec<BetweenItem>,
    /// §1.5's slot, and §1.2's *"last value wins"* made real: the last payload seen for each
    /// SessionMeta family member. An identical repeat is SUPPRESSED rather than queued.
    ///
    /// **Keyed on [`crate::machinery::meta_identity`], not on the frame.** The four
    /// `system/init` frames in `run9` differ ONLY by a per-frame `uuid`, so a verbatim
    /// comparison — which is what the ACP path could afford — would suppress nothing at all
    /// and this whole mechanism would be dead code that looked alive.
    ///
    /// **Per client, so per lease.** A rotation installs a fresh `NativeClient` with an
    /// empty slot, and the successor's first `system/init` is therefore recorded again. That
    /// is correct and not an oversight: it is a different session's statement about itself,
    /// and suppressing it would make the record claim the predecessor's tool list was the
    /// successor's.
    last_meta: std::collections::HashMap<String, Value>,
    /// Identical SessionMeta repeats not queued. Counted, not rendered — the record it would
    /// produce says nothing the retained one does not.
    suppressed: u64,
    /// Items refused because the buffer was full. Reported as a marker record at the next
    /// drain, then reset.
    dropped: u64,
    /// The lane's own counter. NOT §1.4 G1's shared per-turn counter and deliberately not
    /// pretending to be: there is no turn here and no text to interleave with, so this
    /// numbers the lane and nothing else. It is assigned at DRAIN (single-threaded, in the
    /// spine's call) rather than at `offer` (the reader thread), which is the same discipline
    /// §1.4 argues for on the in-turn path.
    next_seq: u64,
}

impl BetweenTurn {
    /// Park one frame the reader thread could not route.
    fn offer_frame(&mut self, frame: Value) {
        let title = crate::machinery::frame_title(&frame);
        // The ONE deliberate drop (§1.2), and it does not become less deliberate for
        // arriving between turns: the ledger already holds the CEO's words verbatim and
        // fsync'd. `from_native_between_turn` enforces it too; short-circuiting here keeps a
        // dropped frame from consuming a queue slot.
        if title == "user:text" {
            return;
        }
        if crate::machinery::is_session_meta(&title) {
            let identity = crate::machinery::meta_identity(&frame);
            if self.last_meta.get(&title) == Some(&identity) {
                self.suppressed += 1;
                return;
            }
            self.last_meta.insert(title, identity);
        }
        self.push(BetweenItem::Frame(frame));
    }

    fn push(&mut self, item: BetweenItem) {
        if self.queue.len() >= BETWEEN_TURN_MAX {
            self.dropped += 1;
            return;
        }
        self.queue.push(item);
    }

    /// Take everything parked, normalized, in arrival order. `thread_id` / `internal` are
    /// still unstamped — only the spine knows those (§1.5).
    fn drain(&mut self, session_id: &str) -> Vec<MachineryRecord> {
        let mut out = Vec::new();
        for item in std::mem::take(&mut self.queue) {
            let records = match item {
                BetweenItem::Frame(f) => {
                    MachineryRecord::from_native_between_turn(&f, session_id, self.next_seq)
                }
                BetweenItem::Permission { request, chosen } => {
                    vec![MachineryRecord::from_permission_request(&request, &chosen, session_id, self.next_seq)]
                }
            };
            // A dropped frame consumes no position, exactly as `prompt`'s loop does not
            // advance `seq` for a frame that normalizes to nothing.
            self.next_seq += records.len() as u64;
            out.extend(records);
        }
        if self.dropped > 0 {
            let seq = self.next_seq;
            self.next_seq += 1;
            out.push(MachineryRecord::between_turn_overflow(self.dropped, session_id, seq));
            self.dropped = 0;
        }
        out
    }

    /// Identical SessionMeta repeats suppressed by the slot, for the whole life of this
    /// client. Diagnostic: it is the number the "last value wins" rule saved, and a test
    /// asserts on it rather than on the absence of rows.
    fn suppressed(&self) -> u64 {
        self.suppressed
    }
}

#[derive(Default)]
struct OperationCancellation {
    active: bool,
    requested: bool,
}

#[derive(Clone)]
enum ActionGrant {
    Onboarding(std::path::PathBuf),
    Continuity(std::path::PathBuf),
    /// The assignment register's grant (`assignment_tools.rs`). Conversation leases only.
    Assignments(std::path::PathBuf),
}

impl ActionGrant {
    fn set(&self, allowed: bool) -> Result<(), String> {
        match self {
            Self::Onboarding(path) => crate::onboarding_tools::set_actions_allowed(path, allowed),
            Self::Continuity(path) => crate::ecs::set_actions_allowed(path, allowed).map_err(|e| e.to_string()),
            // **An absent assignment scope is not a failure to grant; it is nothing to
            // grant.** The scope is written by `prepare_work_turn`, which is the first
            // point at which a company and a conversation exist — so before a thread is
            // bound there is no file, and opening or closing a grant over it is not a
            // meaningful operation. It fails CLOSED either way: with no scope the register
            // tool refuses on its own ("RichOS has not opened this conversation for
            // assignments"), and a deleted scope is the strongest revocation there is.
            //
            // A scope that EXISTS and cannot be written is still a hard failure, which is
            // what takes the lease down in the loop above — the same rule the other two
            // grants follow.
            Self::Assignments(path) if !path.exists() => Ok(()),
            Self::Assignments(path) => crate::assignment_tools::set_actions_allowed(path, allowed),
        }
    }
    fn path(&self) -> &Path {
        match self { Self::Onboarding(path) | Self::Continuity(path) | Self::Assignments(path) => path }
    }
}

/// A live session to a native `claude` child.
pub struct NativeClient {
    child: crate::owned_process::OwnedChild,
    settle_workers_on_stop: bool,
    stdin: Arc<Mutex<ChildStdin>>,
    session_id: String,
    next_id: AtomicI64,
    /// Control-request replies, keyed by our `request_id`.
    pending: Arc<Mutex<std::collections::HashMap<String, Sender<Value>>>>,
    /// The currently in-flight turn's sink for streamed chunks.
    ///
    /// **No request id, and that is a wire difference worth naming.** ACP's `session/prompt`
    /// was a JSON-RPC request whose response id identified the turn. Here a turn is opened by
    /// a `user` frame that carries no id and closed by a `result` frame that carries none
    /// either, so "the turn in flight" is positional: there is at most one, and the next
    /// `result` ends it.
    current_prompt: Arc<Mutex<Option<Sender<ChunkMsg>>>>,
    operation_cancel: Arc<Mutex<OperationCancellation>>,
    action_grants: Vec<ActionGrant>,
    reader_closed: Arc<AtomicBool>,
    /// §1.5's machinery sink INDEPENDENT of the prompt channel.
    between: Arc<Mutex<BetweenTurn>>,
    /// The child's own stderr, bounded, so a startup failure can quote it verbatim.
    stderr_tail: Arc<Mutex<std::collections::VecDeque<String>>>,
    /// Shared with the reader thread, so `skills_verdict()` can answer what the child said
    /// about `--plugin-dir` without going through the turn channel.
    reader_state: Arc<Mutex<ReaderState>>,
    _reader: JoinHandle<()>,
    _stderr: JoinHandle<()>,
}

/// The mutable state the reader thread carries across frames within one turn.
///
/// Held behind one `Mutex` rather than separate atomics because the fields are only ever read
/// and written together, on one thread, and a single lock makes that obvious.
///
/// `Default` is written out below rather than derived, because `skills_verdict`'s honest
/// starting value is `NotYetReported` and a derived default would be whichever variant happens
/// to be declared first.
struct ReaderState {
    permissions: Option<crate::permissions::ScopedPermissions>,
    /// Did the child list all five `richos_work` tools? [`InitFact`], not `bool` — see its
    /// doc for what the collapse cost.
    work_tools_loaded: InitFact,
    /// Did the child list `mcp__richos_assignments__record`? A fact from its own init
    /// inventory, never from the config having been accepted (`assignment_tools.rs`).
    assignment_tool_loaded: bool,
    /// Did the child list `mcp__richos_status__background_work`? Same rule, and this one is
    /// ASSERTED rather than merely recorded (`requires_status_tool`): it is the front desk's
    /// only read once the work tools are refused.
    status_tool_loaded: bool,
    /// Did the child come up in `permissionMode: auto`? [`InitFact`], for the same reason.
    automatic_permissions: InitFact,
    /// Host-owned phase, never set by a model frame.
    context_only: bool,
    /// The model this session is running, from `system/init.model`.
    ///
    /// **Load-bearing, and finding §10 of the spike is why.** The probe's console line took
    /// an arbitrary entry from `result.modelUsage` and printed `contextWindow: 200000` —
    /// which is `claude-haiku-4-5`'s window, from a background side-call, not the session
    /// model's. The session model reports **1,000,000**. Keying the denominator by name is
    /// the difference between a watermark that rotates at 70% of a million and one that
    /// rotates at 70% of two hundred thousand.
    session_model: Option<String>,
    /// The context window, learned from a completed turn's `result.modelUsage`.
    ///
    /// **Spike caveat C3 lives in this `Option`.** The numerator is available mid-turn; the
    /// denominator only once a turn has ENDED, and the `initialize` reply lists five models
    /// and carries no `contextWindow` field at all (verified). So on the first turn of a
    /// fresh lease this is `None`, no measurement is emitted, and the spine stays on its
    /// chars÷4 estimate — which `spine.rs` already treats as a first-class state
    /// (`WatermarkSource::Estimate`). It is a real gap, it is small, and it is not papered
    /// over with a guessed denominator.
    ///
    /// **And smaller than C3 implies, measured live 2026-08-31.** The lease's first turn is
    /// the RE-PRIME turn (`Cognition::reprime`), which ends and fills this in before the CEO
    /// is handed a turn at all — `examples/watermark_roundtrip.rs` reports
    /// `source=measured` after his FIRST prompt. The gap belongs to a lease that was never
    /// primed, and nothing else.
    context_window: Option<u64>,
    /// Whether the binary actually loaded RichOS's skills, read off `system/init.plugins`.
    ///
    /// **The mitigation `--permission-prompt-tool` cannot have.** This file's module doc records
    /// that a flag which is still ACCEPTED but silently stops working is undetectable, because
    /// the initialize reply carries no field naming the permission prompt tool. For
    /// [`PLUGIN_DIR`] that field EXISTS — the init frame lists every loaded plugin by name,
    /// path and version (measured, `inner-doctrine-skills-2026-09-06/` cell K2) — so the same
    /// class of silent failure is caught here rather than merely regretted.
    ///
    /// It starts [`skills::SkillsVerdict::NotYetReported`] and stays there for a lease that has
    /// never run a turn, because the init frame lands with the first TURN and not with the
    /// handshake. That is a third state, not a pessimistic default: "nobody has told us" and
    /// "we were told no" call for opposite responses.
    skills_verdict: crate::skills::SkillsVerdict,
    /// Both exact app-owned onboarding tools, as reported by the child on its first turn.
    onboarding_tools_verdict: crate::onboarding_tools::OnboardingToolsVerdict,
    continuity_tools_loaded: bool,
    /// Did the child list [`crate::engine_profile::PLUGIN_NAME`] in `system/init.plugins`?
    ///
    /// **[`InitFact`] and not `bool`, and this is the field that proved why.** It starts
    /// [`InitFact::NotYetReported`] and stays there for a lease that has never run a turn —
    /// a third state, not a pessimistic default, exactly as `skills_verdict` above it.
    engine_plugin_loaded: InitFact,
    /// Did the child offer **its own** `ToolSearch` tool on this session?
    ///
    /// **The loudness layer for [`TOOL_SEARCH_ENV`], and the one fact that can catch the
    /// knob going away.** When the binary defers tools, the model has to DISCOVER the
    /// register before it can call it, and that discovery is a round trip the CEO waits
    /// through: measured at 3.9 s and again at 7.6 s on one question turn
    /// (`docs/verification/question-receipt-2026-09-18.md`, run 2). `ToolSearch` in the
    /// child's own init inventory is the wire saying deferral is live, so it is READ here
    /// rather than inferred from the environment variable having been set — exactly the
    /// argument `skills_verdict` above makes about `--plugin-dir`.
    ///
    /// [`InitFact`], for the reason the three facts above it are: before the first turn,
    /// nobody has told us.
    tool_search_offered: InitFact,
    /// Has the model said anything to the CEO YET on the turn in flight?
    ///
    /// **Host-owned, reset at the start of every turn, never set by a model frame** — the
    /// same shape as `context_only` above. It exists for one gate: the continuity
    /// checkpoint is bookkeeping, and bookkeeping must not be written while he is still
    /// waiting for his first word (`front-desk.md`, "The record").
    /// [`NativeClient::handle_agent_request`] reads it.
    spoken_this_turn: bool,
    /// **The `tool_use` id of the register call on the turn in flight**, so its result can be
    /// recognized when it comes back.
    ///
    /// Keyed on the id and never on the tool name, because a `tool_result` carries no name at
    /// all (`machinery.rs`: *"a `tool_result` knows no tool name"*) — the id is the only thing
    /// that ties the answer to the question on this wire. Host-owned, reset with the send.
    register_call_id: Option<String>,
    /// **The sentence the APP said on this turn, off the register's own answer.**
    ///
    /// `Some` means his first words have already reached him from the host, at the instant the
    /// register returned, and the model's own copy of them is therefore withheld
    /// ([`WITHHELD_AFTER_THE_RECEIPT`]). `None` is every other turn, on which this file behaves
    /// exactly as it did before 2026-09-18.
    receipt_said: Option<String>,
    /// What was withheld after the receipt, kept so the turn's end can SAY what it took.
    withheld_after_receipt: String,
}

impl Default for ReaderState {
    fn default() -> Self {
        ReaderState {
            permissions: None,
            work_tools_loaded: InitFact::NotYetReported,
            assignment_tool_loaded: false,
            status_tool_loaded: false,
            automatic_permissions: InitFact::NotYetReported,
            context_only: false,
            session_model: None,
            context_window: None,
            skills_verdict: crate::skills::SkillsVerdict::NotYetReported,
            onboarding_tools_verdict: crate::onboarding_tools::OnboardingToolsVerdict::NotYetReported,
            continuity_tools_loaded: false,
            engine_plugin_loaded: InitFact::NotYetReported,
            tool_search_offered: InitFact::NotYetReported,
            spoken_this_turn: false,
            register_call_id: None,
            receipt_said: None,
            withheld_after_receipt: String::new(),
        }
    }
}

/// Prove, BEFORE spawning, which of a launch's two preconditions is not met.
///
/// **This function exists because `ENOENT` is ambiguous by construction.**
/// `Command::spawn` raises `std::io::ErrorKind::NotFound` when the executable is missing
/// AND when `current_dir` names a directory that is not there. One errno, two faults, two
/// completely different fixes — and the mapping that guessed "missing binary" told the CEO
/// on 2026-09-01 that `~/.local/bin/claude` was not found while it sat on his disk
/// and only the engine directory was absent
/// (`docs/verification/payload-inventory-2026-09-01/README.md` §7). Whoever debugs that on a
/// customer's machine looks in exactly the wrong place.
///
/// **Order, and it is a decision.** The binary is checked first, because "Claude Code is not
/// installed" is the larger and more upstream errand of the two: an install with neither the
/// binary nor the engine directory needs the 197 MB install before the 4 MB directory means
/// anything. Each check names its own path, so a multi-fault install still gets a true
/// sentence — just the first true sentence rather than all of them.
///
/// **What it deliberately does NOT check.** A bare name resolved through `PATH` (the last
/// resort in [`resolve_claude_bin`]) has no path to test, so it falls through to the spawn,
/// where `ENOENT` is now unambiguous *because this function already cleared the working
/// directory*. Nothing here executes the binary or reads its contents: existence, file type
/// and the execute bit only.
fn preflight(bin: &Path, cwd: &Path, doctrine: Option<&Path>, skills: Option<&Path>) -> Result<(), NativeError> {
    // ---- the binary -------------------------------------------------------------------
    if bin.components().count() > 1 {
        match std::fs::metadata(bin) {
            Err(_) => return Err(NativeError::BinaryMissing { path: bin.display().to_string() }),
            Ok(meta) if meta.is_dir() => {
                return Err(NativeError::BinaryNotExecutable {
                    path: bin.display().to_string(),
                    why: "it is a directory".to_string(),
                })
            }
            Ok(meta) => {
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    // Any execute bit — owner, group or other. A finer-grained answer would
                    // need the effective uid/gid, and `0o111 == 0` is the case that is
                    // certainly unrunnable; anything subtler surfaces as the
                    // `PermissionDenied` arm at the spawn, which maps to this same variant.
                    if meta.permissions().mode() & 0o111 == 0 {
                        return Err(NativeError::BinaryNotExecutable {
                            path: bin.display().to_string(),
                            why: format!("no execute permission (mode {:o})", meta.permissions().mode() & 0o777),
                        });
                    }
                }
                let _ = meta;
            }
        }
    }

    // ---- the working directory --------------------------------------------------------
    match std::fs::metadata(cwd) {
        Err(_) => return Err(NativeError::WorkingDirMissing { path: cwd.display().to_string() }),
        Ok(meta) if !meta.is_dir() => {
            return Err(NativeError::WorkingDirNotADirectory { path: cwd.display().to_string() })
        }
        Ok(_) => {}
    }

    // ---- the standing instruction ------------------------------------------------------
    //
    // `claude` itself refuses a missing file — `Error: Append system prompt file not found:
    // <path>`, exit 1, zero bytes of stdout, measured 2026-09-06 on 2.1.263 — so this check is
    // not what makes the failure loud. It makes it EARLY and SPECIFIC: a refusal here names the
    // doctrine file and says what it is for, instead of arriving as a startup error the reader
    // has to attribute among the four things that can produce one. Same reasoning, and the same
    // incident, as `WorkingDirMissing`: reporting one fault as another sends whoever set RichOS
    // up looking in the wrong place.
    //
    // EMPTY IS ALSO A FAILURE. A zero-byte file is a file `claude` accepts, so it would hand
    // the CEO a generic assistant with a clean handshake — precisely the silent degradation
    // this channel was chosen to avoid.
    if let Some(doctrine) = doctrine {
        match std::fs::metadata(doctrine) {
            Err(e) => {
                return Err(NativeError::DoctrineMissing {
                    path: doctrine.display().to_string(),
                    why: e.to_string(),
                })
            }
            Ok(meta) if !meta.is_file() => {
                return Err(NativeError::DoctrineMissing {
                    path: doctrine.display().to_string(),
                    why: "it is not a file".to_string(),
                })
            }
            Ok(meta) if meta.len() == 0 => {
                return Err(NativeError::DoctrineMissing {
                    path: doctrine.display().to_string(),
                    why: "it is empty, and an empty instruction is no instruction".to_string(),
                })
            }
            Ok(_) => {}
        }
    }

    // ---- the skills ---------------------------------------------------------------------
    //
    // THIS ONE IS NOT A NICETY. `claude` refuses a missing `--append-system-prompt-file` by
    // itself; it accepts a missing `--plugin-dir` in silence — exit 0, clean handshake,
    // `plugins: []`, an ordinary turn (measured, cell K4). So if this check is ever removed,
    // deleting a skill file stops being an error and becomes a product that is quietly less
    // than it says it is. The whole evening was about that failure shape.
    if let Some(skills) = skills {
        if let Err((path, why)) = crate::skills::verify_present(skills) {
            return Err(NativeError::SkillsMissing { path: path.display().to_string(), why });
        }
    }

    Ok(())
}

/// The per-lease MCP config the app writes when it spawns a child.
///
/// **Extracted from `spawn_with_tools` so it can be asserted without spawning anything.**
/// The background-work spec's §5.8a-ii seam 1 is a claim about what is IN this object and
/// what is not, and a claim of that shape is worth nothing if the only way to check it is
/// to start a provider. The negative — `richos_continuity` absent from a work lease's
/// config — is exactly the kind of assertion the spec's own checker had to be rebuilt to
/// be able to make.
///
/// - `richos_onboarding` is served by the app's own executable and is on the **conversation**
///   lease only. **It was on both until 2026-09-18, and that sentence is where Ray's
///   candidate-.8 row 1 was written down as a design fact.** Its scope is written only by
///   `spine.rs` (`:3093`, `:3278`), so the work lease's copy named a file nothing could ever
///   create, and opening the grant over it was the first act of the work lease's first turn.
/// - `richos_continuity` is on the **conversation** lease only (seam 1). The work lease
///   never calls `checkpoint`, `receipt` or `brief`; leaving the server registered would
///   have given it un-prompted access, because `permissions.rs:58-59` auto-allows both of
///   that server's tools on a process-global tool-name match that discriminates on nothing
///   per-lease, and its own gate is `actions_allowed`, which §5.4's standing grant supplies.
/// - **`richos_work` is on the WORK lease only, as of the CEO's Two Riches page.** It used
///   to be on both, and the comment here said so in its own words: *"`richos_work` is on
///   both, because the work lease is the one that needs it most."* The page's sense-check
///   note 3 is *"The front desk gets no orchestration tools, so it cannot drift into doing
///   the work"*, and his own sentence for the shape is *"the job of the front desk Rich is
///   solely talking to the CEO and relaying info to and from the back-end Rich."* A front
///   desk holding `prepare`, `inspect`, `complete`, `repositories` and `integrate` is a
///   front desk that CAN do the work, and a model with a tool in front of it eventually
///   uses it. **The register is what the front desk hands work over with**
///   (`richos_assignments.record`, below) and `richos_status` is what it looks with.
/// - `richos_status` is on the **conversation** lease only (`status_tools.rs`). It is the
///   other half of note 3 and it is not optional beside the refusal above: take the work
///   tools away and the front desk has no READ at all — every status surface in this app is
///   a Tauri command reaching the webview, which the model never sees (Sage's check of the
///   page, finding 6).
fn mcp_config(executable: &Path, onboarding_scope: &Path, assignments_scope: &Path, status_scope: &Path,
    continuity: Option<(&crate::ecs::EcsBridge, &Path)>,
    profile: Option<&crate::engine_profile::EngineProfile>, role: LeaseRole) -> Value {
    let mut config = json!({"mcpServers": {}});
    // **The company-notes tools, on the CONVERSATION lease only** (`onboarding_tools.rs`).
    //
    // **This was on both leases until 2026-09-18, and it is Ray's candidate-.8 row 1.** The
    // scope these tools read is written by `Cognition::set_onboarding_scope`, which is called
    // from two places and both are the conversation's (`spine.rs:3093`, `spine.rs:3278`). So
    // a work lease held two tools over a file nothing could ever write, and the first thing
    // its turn did was open a grant over it — see the grant list in `spawn_with_tools`.
    //
    // It belongs here for the same reason the register does, one paragraph down: saving the
    // CEO's answers about his own company is something he says in a visible turn, and a back
    // end that could rewrite them with a standing grant and no turn at all is the drift his
    // page closes. The back end needs them for nothing: its job is named in the assignment.
    if role == LeaseRole::Conversation {
        config["mcpServers"]["richos_onboarding"] = json!({
            "type": "stdio", "command": executable,
            "args": ["--onboarding-mcp", onboarding_scope]
        });
    }
    // **The turn-ending tool, on the CONVERSATION lease only** (`assignment_tools.rs`).
    // A work lease that could register more assignments would be a model giving itself
    // work, which is nobody's decision to make — and §1.1's boundary is about HIS turn, so
    // the tool belongs where his turn is.
    if role == LeaseRole::Conversation {
        config["mcpServers"][crate::assignment_tools::SERVER_NAME] = json!({
            "type": "stdio", "command": executable,
            "args": ["--assignments-mcp", assignments_scope]
        });
        // **The front desk's eyes** (`status_tools.rs`). Registered in the same breath as
        // the register and on the same lease, because the two are the whole of what the
        // front desk is allowed to do with work: hand it over, and look at it.
        config["mcpServers"][crate::status_tools::SERVER_NAME] = json!({
            "type": "stdio", "command": executable,
            "args": ["--status-mcp", status_scope]
        });
    }
    if let Some((bridge, scope)) = continuity.filter(|_| role == LeaseRole::Conversation) {
        config["mcpServers"]["richos_continuity"] = json!({"type":"stdio", "command":bridge.python,
            "args":[bridge.component.join("adapters/mcp.py"),scope], "env":{"PYTHONDONTWRITEBYTECODE":"1"}});
    }
    if let (Some(profile), Some((bridge, scope))) = (profile, continuity.filter(|_| role == LeaseRole::Work)) {
        config["mcpServers"]["richos_work"] = json!({"type":"stdio", "command":bridge.python,
            "args":[profile.engine.join("mega-lander/app.py"),scope], "env":{"PYTHONDONTWRITEBYTECODE":"1"}});
    }
    config
}

impl NativeClient {
    /// Spawn `claude`, run the `initialize` handshake, and return a client whose session id
    /// is already known.
    ///
    /// **The handshake is not optional and its failure is not recoverable here.** It is the
    /// one moment at which a rejected flag, a missing login, or a binary that is not `claude`
    /// at all can be caught before the CEO types anything — so it is done eagerly, with a
    /// bound, and its failure is a hard [`NativeError`] carrying the child's own stderr.
    /// **`doctrine` is required and is not an `Option`.** The chat lease is the CEO's
    /// conversation, and a chat lease with no standing instruction is the generic-Claude
    /// failure this whole channel exists to make impossible (`doctrine.rs`). Making it a
    /// parameter rather than something this function resolves for itself is the same call
    /// `entity.rs` makes about its own directory: the shell resolves `app_data_dir()` and that
    /// is the authority, so this file does not carry a second opinion about where it lives.
    pub fn spawn(bin: &Path, cwd: &Path, doctrine: &Path, skills: &Path) -> Result<Self, NativeError> {
        Self::spawn_with_tools(bin, cwd, Some((doctrine, skills)), None, None, None, None, LeaseRole::Conversation)
    }

    fn spawn_with_tools(bin: &Path, cwd: &Path, standing: Option<(&Path, &Path)>, onboarding: Option<(&Path, &Path, &Path, &Path)>, continuity: Option<(&crate::ecs::EcsBridge, &Path)>, profile: Option<&crate::engine_profile::EngineProfile>, control: Option<&crate::steering::TurnControl>, role: LeaseRole) -> Result<Self, NativeError> {
        let (doctrine, skills) = (standing.map(|s| s.0), standing.map(|s| s.1));
        preflight(bin, cwd, doctrine, skills)?;
        let session_id = uuid::Uuid::new_v4().to_string();
        let desktop_doctrine = match (profile, doctrine) {
            (Some(profile), Some(doctrine)) => Some(profile.standing_doctrine(doctrine, role)
                .map_err(|e| NativeError::Protocol(e.to_string()))?),
            _ => None,
        };
        let mut args = match standing {
            Some((d, s)) => chat_child_args(&session_id, desktop_doctrine.as_deref().unwrap_or(d), s),
            None => child_args(&session_id),
        };
        if let Some((executable, scope, assignments, status)) = onboarding {
            let config = mcp_config(executable, scope, assignments, status, continuity, profile, role);
            args.extend(["--strict-mcp-config".into(), "--mcp-config".into(), config.to_string()]);
        }
        // The supervisor observes parent death, including a crash where Rust
        // destructors cannot run. Its provider child receives the actual PID.
        let mut command = if let Some(profile) = profile {
            let mut supervisor = Command::new(&profile.runtime.python);
            supervisor.arg(profile.engine.join("scripts/provider-supervisor.py")).arg(bin);
            supervisor
        } else { Command::new(bin) };
        crate::owned_process::OwnedChild::configure(&mut command);
        // **The conversation's tools are RESIDENT from its first turn** ([`TOOL_SEARCH_ENV`]
        // says what that costs when they are not, with the frame timings). Set here rather
        // than in `EngineProfile::configure` because that function does not know the role,
        // and this is a per-role decision: it is set before `configure` runs and survives it,
        // which strips only `RICHOS_`/`LORO_`/`ECS_`/`GIT_` names. It reaches the provider
        // through `provider-supervisor.py` too — that supervisor `os.execvp`s, so the child
        // inherits `os.environ` unchanged (`engine/scripts/provider-supervisor.py:24`).
        if let Some((name, value)) = tool_residency_env(role) {
            command.env(name, value);
        }
        if let Some(profile) = profile {
            let scope = continuity.ok_or_else(|| NativeError::Protocol("desktop engine needs a scoped continuity bridge".into()))?.1;
            profile.configure(&mut command, &session_id, scope);
        }
        let mut child = command
            .args(args)
            .current_dir(cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| match e.kind() {
                // `preflight` has ALREADY proved the working directory exists and is a
                // directory, which is what makes this mapping sound: after that check, the
                // only thing left that can raise `ENOENT` here is the executable itself —
                // in practice a bare name that is not on `PATH`, the one case preflight
                // cannot check. Before that check this arm was a guess, and it guessed
                // wrong every time the engine directory was the missing thing.
                std::io::ErrorKind::NotFound => NativeError::BinaryMissing { path: bin.display().to_string() },
                std::io::ErrorKind::PermissionDenied => NativeError::BinaryNotExecutable {
                    path: bin.display().to_string(),
                    why: "the operating system refused to execute it".to_string(),
                },
                _ => NativeError::Io(e),
            })?;

        let stdin = Arc::new(Mutex::new(child.stdin.take().ok_or(NativeError::Closed)?));
        let stdout = child.stdout.take().ok_or(NativeError::Closed)?;
        let stderr = child.stderr.take().ok_or(NativeError::Closed)?;

        let pending: Arc<Mutex<std::collections::HashMap<String, Sender<Value>>>> =
            Arc::new(Mutex::new(std::collections::HashMap::new()));
        let current_prompt: Arc<Mutex<Option<Sender<ChunkMsg>>>> = Arc::new(Mutex::new(None));
        let between: Arc<Mutex<BetweenTurn>> = Arc::new(Mutex::new(BetweenTurn::default()));
        let state: Arc<Mutex<ReaderState>> = Arc::new(Mutex::new(ReaderState::default()));
        if let (Some(profile), Some((_, scope))) = (profile, continuity) {
            state.lock().unwrap().permissions = Some(crate::permissions::ScopedPermissions {desk: profile.permissions.clone(), scope: scope.into()});
        }
        let stderr_tail: Arc<Mutex<std::collections::VecDeque<String>>> =
            Arc::new(Mutex::new(std::collections::VecDeque::new()));
        // Reset at every `message_start`; read at every `assistant` frame. See
        // `dispatch`'s text handling — it is the guard against a silent clean-output
        // regression if `--include-partial-messages` ever stops working.
        let text_deltas: Arc<AtomicUsize> = Arc::new(AtomicUsize::new(0));

        // Drain stderr so the child never blocks on a full pipe, and KEEP THE TAIL, because
        // on a rejected flag that one line is the entire diagnosis. Diagnostics are
        // machinery — they NEVER reach the CEO; the tail is for the error message and for
        // developer debugging.
        let tail = Arc::clone(&stderr_tail);
        let stderr_handle = std::thread::spawn(move || {
            let reader = BufReader::new(stderr);
            for line in reader.lines().map_while(Result::ok) {
                if std::env::var("RICHOS_CLAUDE_DEBUG").is_ok() {
                    eprintln!("[claude-stderr] {line}");
                }
                let mut t = tail.lock().unwrap();
                if t.len() >= STDERR_TAIL_LINES {
                    t.pop_front();
                }
                t.push_back(line);
            }
        });

        let reader_closed = Arc::new(AtomicBool::new(false));
        let reader_closed_flag = Arc::clone(&reader_closed);
        let reader_stdin = Arc::clone(&stdin);
        let reader_pending = Arc::clone(&pending);
        let reader_current = Arc::clone(&current_prompt);
        let reader_between = Arc::clone(&between);
        let reader_state = Arc::clone(&state);
        let reader_text_deltas = Arc::clone(&text_deltas);
        let reader_handle = std::thread::spawn(move || {
            let reader = BufReader::new(stdout);
            for line in reader.lines().map_while(Result::ok) {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                let msg: Value = match serde_json::from_str(line) {
                    Ok(v) => v,
                    Err(_) => continue,
                };
                Self::dispatch(
                    msg,
                    &reader_stdin,
                    &reader_pending,
                    &reader_current,
                    &reader_between,
                    &reader_state,
                    &reader_text_deltas,
                );
            }
            // stdout closed. §5.2's POSITIVE termination signal: the child's stdout reached
            // EOF, which is a fact about the child and not an inference from silence. Fail
            // every waiter so no caller hangs forever.
            reader_pending.lock().unwrap().clear();
            let mut current = reader_current.lock().unwrap();
            reader_closed_flag.store(true, Ordering::SeqCst);
            if let Some(sink) = current.take() {
                let _ = sink.send(ChunkMsg::Done(json!({ "stop_reason": "child_exited" })));
            }
        });

        let mut client = NativeClient {
            child: crate::owned_process::OwnedChild::new(child),
            settle_workers_on_stop: profile.is_some(),
            stdin,
            session_id,
            next_id: AtomicI64::new(1),
            pending,
            current_prompt,
            operation_cancel: Arc::new(Mutex::new(OperationCancellation::default())),
            // The assignments grant rides with the other two: open at turn start, closed at
            // turn end, by the same all-or-nothing loop. So `richos_assignments.record`
            // is reachable in exactly the window `richos_onboarding` is — a visible CEO
            // turn — and in no other, which is what spec §5.1 says about a request with no
            // turn open, kept by construction rather than by a check inside the tool alone.
            // **The status scope takes no grant and so is not in this list.** It is the one
            // app-owned scope with nothing to open or close: `status_tools.rs` reads and
            // writes nothing, and its own module comment says why gating a read on a rule
            // written for writes would only produce a front desk that goes blind between
            // his turns.
            //
            // **THE ONBOARDING GRANT IS CONVERSATION-ONLY, AND THIS LINE IS RAY'S
            // CANDIDATE-.8 ROW 1.** Until 2026-09-18 only `Assignments` carried the role
            // filter, so a WORK lease took a grant over `{identity}-onboarding.json` —
            // a path `start_work_lease` computes and nothing on earth writes
            // (`Cognition::set_onboarding_scope` is called from `spine.rs:3093` and
            // `spine.rs:3278`, both the conversation's). `prompt`'s first act is to open
            // every grant in this list, so the work lease's first turn opened a grant over
            // a file that was not there, `read_scope` mapped the missing file to
            // *"Choose a company before saving interview answers."*
            // (`onboarding_tools.rs:137`), and `prompt` returned that as
            // `CognitionError::Io` before sending the turn. Measured on his walk: **6.317 s**
            // after registration, no model token spent, `notes.txt` unchanged.
            //
            // **Deliberately a role filter and not an `exists()` guard like
            // `Assignments`'s.** On a conversation lease a missing onboarding scope means no
            // company is bound yet, and failing hard there is the check that stops a model
            // writing company notes with no company chosen — that sentence is *right* in
            // that seat. The defect was never the sentence; it was a work lease standing in
            // the seat that says it.
            action_grants: onboarding.filter(|_| role == LeaseRole::Conversation)
                .map(|(_, path, _, _)| ActionGrant::Onboarding(path.into())).into_iter()
                .chain(onboarding.filter(|_| role == LeaseRole::Conversation)
                    .map(|(_, _, path, _)| ActionGrant::Assignments(path.into())))
                .chain(continuity.map(|(_, path)| ActionGrant::Continuity(path.into()))).collect(),
            reader_closed,
            between,
            stderr_tail,
            reader_state: Arc::clone(&state),
            _reader: reader_handle,
            _stderr: stderr_handle,
        };
        client.handshake_cancellable(control)?;
        Ok(client)
    }

    /// The `initialize` control handshake. Liveness, and nothing else.
    ///
    /// **It reads the reply's `subtype` and keeps none of its contents.** That reply carries
    /// the customer's `account` (email, organization, `subscriptionType`) and RichOS may
    /// never collect, store or intermediate it — see the module doc's licence section. The
    /// reply is dropped on the floor the moment it proves the child is alive.
    ///
    /// It costs NO API turn: measured 697.9 ms on 2.1.252, and `run10` of the spike
    /// established that control requests are free.
    fn handshake_cancellable(&mut self, control: Option<&crate::steering::TurnControl>) -> Result<(), NativeError> {
        let (tx, rx): (Sender<Value>, Receiver<Value>) = channel();
        self.pending.lock().unwrap().insert("req_init".to_string(), tx);
        let msg = json!({
            "type": "control_request", "request_id": "req_init",
            "request": { "subtype": "initialize", "hooks": {} }
        });
        if let Err(e) = Self::write_line(&self.stdin, &msg) {
            // ONE CAUSE, ONE SENTENCE — and until 2026-09-04 this one had two.
            //
            // A child that rejects a flag writes its line and is gone in a millisecond or
            // two, so whether this process gets the handshake into the pipe before the
            // kernel tears it down is a SCHEDULER RACE and nothing else. Win it and the
            // write succeeds, the reader hits stdout EOF, and the arm below says "the child
            // exited before answering the handshake". Lose it and the write returns `EPIPE`
            // and the operator was told, for the identical fault, "could not write the
            // initialize handshake: claude io: Broken pipe (os error 32)".
            //
            // Two bug reports for one cause, decided by machine speed. This machine wins the
            // race every time; a GitHub `macos-latest` runner lost it on the first public
            // run of `app-spine-ci` (33872961756, 2026-09-04) and the only test that names
            // the sentence went red — over the product's nondeterminism, not over the test.
            //
            // THE EXIT IS CONFIRMED, NEVER INFERRED. A broken pipe is a positive fact about
            // the PIPE and only a guess about the process: a child that closes its input and
            // stays up breaks it too, and "the child exited" would then be a false statement
            // in a diagnosis. So the pipe sends us to `waitpid`, and `waitpid` decides.
            let broken = matches!(&e, NativeError::Io(io) if io.kind() == std::io::ErrorKind::BrokenPipe);
            let exited = broken && self.child_has_exited();
            return Err(self.startup_error(Self::write_failure_reason(&e, broken, exited)));
        }
        let deadline = std::time::Instant::now() + HANDSHAKE_TIMEOUT;
        let response = loop {
            if control.and_then(|c| c.stop_claim()).is_some() {
                self.pending.lock().unwrap().remove("req_init");
                return Err(NativeError::Protocol("Connection stopped at your request.".into()));
            }
            let Some(remaining) = deadline.checked_duration_since(std::time::Instant::now()) else {
                break Err(RecvTimeoutError::Timeout);
            };
            match rx.recv_timeout(remaining.min(std::time::Duration::from_millis(50))) {
                Err(RecvTimeoutError::Timeout) => continue,
                result => break result,
            }
        };
        match response {
            Ok(resp) => {
                let subtype = resp.get("response").and_then(|r| r.get("subtype")).and_then(|v| v.as_str());
                if subtype == Some("success") {
                    // Deliberately NOT reading `response.response.account`. See the doc above.
                    Ok(())
                } else {
                    Err(self.startup_error(format!(
                        "the initialize handshake was refused (subtype {subtype:?})"
                    )))
                }
            }
            // The reader thread cleared the waiters, which it does at stdout EOF — i.e. the
            // child died. On a rejected flag this is the path taken, within milliseconds,
            // and `stderr_tail` holds `error: unknown option '…'`.
            Err(RecvTimeoutError::Disconnected) => {
                Err(self.startup_error("the child exited before answering the handshake".into()))
            }
            Err(RecvTimeoutError::Timeout) => Err(self.startup_error(format!(
                "no answer to the initialize handshake within {}s",
                HANDSHAKE_TIMEOUT.as_secs()
            ))),
        }
    }

    /// Build the loud startup error, quoting the child verbatim.
    ///
    /// Gives the stderr thread a brief moment to catch up first: on a rejected flag the
    /// child writes its one line and exits, and reading the tail the same instant the
    /// waiter is cleared can race the line that IS the diagnosis. 200 ms against a failure
    /// path that only ever runs once, at boot.
    fn startup_error(&self, reason: String) -> NativeError {
        std::thread::sleep(Duration::from_millis(200));
        let stderr = {
            let t = self.stderr_tail.lock().unwrap();
            if t.is_empty() {
                "(nothing on stderr)".to_string()
            } else {
                t.iter().cloned().collect::<Vec<_>>().join(" / ")
            }
        };
        NativeError::Startup { reason, stderr }
    }

    /// Permission callbacks during hidden context are always denied. App-owned onboarding
    /// tools additionally require a scope grant, covering vendor automatic approvals too.
    pub fn prompt_context_only(
        &mut self, text: &str, on_item: &mut dyn FnMut(TurnItem),
    ) -> Result<String, NativeError> {
        self.reader_state.lock().unwrap().context_only = true;
        let result = self.prompt(text, on_item);
        self.reader_state.lock().unwrap().context_only = false;
        result
    }

    /// The sentence a failed handshake WRITE gets, as a pure function of the three facts
    /// that decide it.
    ///
    /// PURE ON PURPOSE. The caller's inputs come out of a race, and a test that had to WIN
    /// that race to exercise an arm would be a test that passes on whichever machine it is
    /// run on — which is the exact defect this function exists to remove. Split out, both
    /// arms are provable on any machine, in microseconds, with no child at all.
    fn write_failure_reason(e: &NativeError, broken_pipe: bool, child_exited: bool) -> String {
        if broken_pipe && child_exited {
            // The same words the `Disconnected` arm below uses, because it is the same fact:
            // the child was gone before it answered.
            "the child exited before answering the handshake".to_string()
        } else if broken_pipe {
            // A live child that shut its own input. Rarer, and a DIFFERENT fault with a
            // different fix, so it does not get to borrow the sentence above.
            "the child closed its input before answering the handshake".to_string()
        } else {
            format!("could not write the initialize handshake: {e}")
        }
    }

    /// Has the child really gone — `waitpid`, not an inference.
    ///
    /// Bounded at ~200 ms because reaping is not instantaneous: the write can return `EPIPE`
    /// the moment the kernel tears the pipe down, a beat before the process is reapable. It
    /// runs once, on a boot that has already failed, so the cost is paid by nothing that
    /// works.
    fn child_has_exited(&mut self) -> bool {
        for _ in 0..40 {
            match self.child.try_wait() {
                Ok(Some(_)) => return true,
                Ok(None) => std::thread::sleep(Duration::from_millis(5)),
                Err(_) => return false,
            }
        }
        false
    }

    /// Route one inbound frame: control response -> waiter, control request -> answered
    /// here, everything else -> the active turn's chunk sink or the between-turn lane.
    #[allow(clippy::too_many_arguments)]
    fn dispatch(
        msg: Value,
        stdin: &Arc<Mutex<ChildStdin>>,
        pending: &Arc<Mutex<std::collections::HashMap<String, Sender<Value>>>>,
        current: &Arc<Mutex<Option<Sender<ChunkMsg>>>>,
        between: &Arc<Mutex<BetweenTurn>>,
        state: &Arc<Mutex<ReaderState>>,
        text_deltas: &Arc<AtomicUsize>,
    ) {
        let ty = msg.get("type").and_then(|v| v.as_str()).unwrap_or("");

        // ---- the control protocol ------------------------------------------------------
        if ty == "control_response" {
            if let Some(id) = msg.get("response").and_then(|r| r.get("request_id")).and_then(|v| v.as_str()) {
                if let Some(tx) = pending.lock().unwrap().remove(id) {
                    let _ = tx.send(msg);
                    return;
                }
            }
            // An unmatched control response is still traffic and is retained rather than
            // dropped (§1.4 G5).
            Self::route(ChunkMsg::Frame(msg.clone()), current, between, &msg);
            return;
        }
        if ty == "control_request" {
            let context_only = state.lock().unwrap().context_only;
            let permissions = state.lock().unwrap().permissions.clone();
            // **Read on the reader thread, which is also the thread the text deltas arrive
            // on** — so "has he heard anything yet" is answered in the order the wire put the
            // two events in, with no race to lose.
            let spoken = state.lock().unwrap().spoken_this_turn;
            Self::handle_agent_request(&msg, stdin, current, between, context_only, spoken, permissions.as_ref());
            return;
        }

        // Nested agent frames are operational evidence, never the lead's words,
        // context watermark or terminal state. In particular, whole-message fallback
        // must not promote worker narration when the lead has no active text stream.
        if msg.get("parent_tool_use_id").is_some_and(|parent| !parent.is_null()) {
            Self::route(ChunkMsg::Frame(msg.clone()), current, between, &msg);
            return;
        }

        // ---- the terminal frame --------------------------------------------------------
        if ty == "result" {
            let mut st = state.lock().unwrap();
            // **THE LOUDNESS LAYER FOR THE WITHHOLDING**, at the one point in a turn that is
            // guaranteed to be reached. Said here rather than per delta: the deltas arrive in
            // pieces and a notice per piece would be a notice per token.
            if !st.withheld_after_receipt.is_empty() {
                let said = st.receipt_said.clone().unwrap_or_default();
                let withheld = st.withheld_after_receipt.trim().to_string();
                let same = withheld == said;
                eprintln!(
                    "{WITHHELD_AFTER_THE_RECEIPT} ({} chars, {}): {withheld:?}",
                    withheld.chars().count(),
                    if same { "the same sentence again" } else { "NOT the sentence the app said" },
                );
            }
            // Learn the denominator for the NEXT turn's watermark, by NAME (finding §10).
            if let (Some(model), Some(usage)) = (st.session_model.clone(), msg.get("modelUsage")) {
                if let Some(w) = usage.get(&model).and_then(|m| m.get("contextWindow")).and_then(|v| v.as_u64()) {
                    st.context_window = Some(w);
                }
            }
            drop(st);
            let sink = current.lock().unwrap().take();
            match sink {
                Some(s) => {
                    let _ = s.send(ChunkMsg::Done(msg));
                }
                // A `result` with no turn in flight is a statement about a turn that has
                // already been answered. It is retained, not dropped.
                None => between.lock().unwrap().offer_frame(msg),
            }
            return;
        }

        // ---- session identity ----------------------------------------------------------
        if ty == "system" && msg.get("subtype").and_then(|v| v.as_str()) == Some("init") {
            let mut st = state.lock().unwrap();
            if let Some(m) = msg.get("model").and_then(|v| v.as_str()) {
                st.session_model = Some(m.to_string());
            }
            // THE SECOND LOUDNESS LAYER FOR `--plugin-dir`. Read once per frame — the init
            // frame repeats every turn and says the same thing, so a later rejection is caught
            // too. The verdict is a FACT FROM THE CHILD, not an inference: `plugins` lists what
            // it actually loaded.
            if st.onboarding_tools_verdict == crate::onboarding_tools::OnboardingToolsVerdict::NotYetReported {
                st.onboarding_tools_verdict = crate::onboarding_tools::verdict_from_init(&msg);
            }
            st.continuity_tools_loaded = ["mcp__richos_continuity__checkpoint", "mcp__richos_continuity__inspect"].iter()
                .all(|name| msg["tools"].as_array().map(|tools| tools.iter().any(|tool| tool.as_str() == Some(name))).unwrap_or(false));
            // **The three tri-state facts are READINGS, and a reading only happens here.**
            // `InitFact::reported` has no way to produce `NotYetReported`, so the three
            // fields can only leave that state inside this handler — which is what makes
            // "nobody has told us" a statement about the wire rather than about the order
            // the app happened to call things in.
            st.work_tools_loaded = InitFact::reported(
                ["mcp__richos_work__repositories", "mcp__richos_work__prepare", "mcp__richos_work__inspect", "mcp__richos_work__integrate", "mcp__richos_work__complete"].iter()
                    .all(|name| msg["tools"].as_array().is_some_and(|tools| tools.iter().any(|tool| tool.as_str() == Some(name)))));
            st.assignment_tool_loaded = crate::assignment_tools::loaded_from_init(&msg);
            st.status_tool_loaded = crate::status_tools::loaded_from_init(&msg);
            st.automatic_permissions = InitFact::reported(msg["permissionMode"] == "auto");
            st.engine_plugin_loaded = InitFact::reported(msg["plugins"].as_array().is_some_and(|plugins|
                plugins.iter().any(|plugin| plugin["name"] == crate::engine_profile::PLUGIN_NAME)));
            // **THE LOUDNESS LAYER FOR [`TOOL_SEARCH_ENV`].** Read every init frame, like the
            // `--plugin-dir` verdict above: the variable is undocumented, so the only honest
            // evidence that it is still doing its job is the child NOT offering its own
            // discovery tool. Announced once, at the transition, on stderr — machinery, never
            // anything the CEO sees (the stderr drain above says why).
            let tool_search = tool_search_from_init(&msg);
            if tool_search == InitFact::Yes && st.tool_search_offered != InitFact::Yes {
                eprintln!(
                    "[richos] THIS SESSION DEFERS ITS TOOLS. `{TOOL_SEARCH_TOOL}` is in the child's own \
                     init inventory, so the register has to be DISCOVERED before it can be called and \
                     the CEO waits a round trip for that (measured: 7.5 s of one 23 s turn). \
                     `{TOOL_SEARCH_ENV}={TOOL_SEARCH_OFF}` is set for this lease and is no longer \
                     having that effect — check `claude --version` against the last release gate."
                );
            }
            st.tool_search_offered = tool_search;
            let before = st.skills_verdict;
            st.skills_verdict = crate::skills::verdict_from_init(&msg);
            if st.skills_verdict == crate::skills::SkillsVerdict::Rejected
                && before != crate::skills::SkillsVerdict::Rejected
            {
                // Diagnostics are machinery and NEVER reach the CEO (see the stderr drain
                // above); this is for whoever is looking at why Rich is thinner than he should
                // be. `preflight` already proved the files are on disk, so reaching here means
                // the BINARY declined them, which is the one case no file check can see.
                eprintln!(
                    "[richos] THE SKILLS DID NOT LOAD. `{PLUGIN_DIR}` was accepted and \
                     `{}` is not in this session's plugin list, so every skill RichOS ships is \
                     absent from this lease. The files passed preflight, so this is the binary \
                     declining them — check `claude --version` against the last release gate.",
                    crate::skills::PLUGIN_NAME
                );
            }
        }

        // ---- the clean-output text path, and its guard ----------------------------------
        if ty == "stream_event" {
            let ev = msg.get("event").unwrap_or(&Value::Null);
            let ev_ty = ev.get("type").and_then(|v| v.as_str()).unwrap_or("");
            if ev_ty == "message_start" {
                text_deltas.store(0, Ordering::SeqCst);
            }
            // **THE REGISTER'S CALL, RECOGNIZED AS IT OPENS.** The id arrives here, on the
            // streamed block start, ~0.3 s to 0.9 s before the complete arguments and ~2 s
            // before the answer (run 3's own frames: 3.122 s, 4.040 s, 6.034 s). Taken from
            // whichever of the two frames arrives first — this one, or the whole `assistant`
            // message below — because a build that stops streaming partial messages must not
            // stop the app from speaking.
            if ev_ty == "content_block_start" {
                let block = ev.get("content_block").unwrap_or(&Value::Null);
                if block.get("type").and_then(|v| v.as_str()) == Some("tool_use")
                    && block.get("name").and_then(|v| v.as_str())
                        == Some(crate::assignment_tools::QUALIFIED_RECORD_TOOL)
                {
                    if let Some(id) = block.get("id").and_then(|v| v.as_str()) {
                        state.lock().unwrap().register_call_id = Some(id.to_string());
                    }
                }
            }
            if ev_ty == "content_block_delta"
                && ev.get("delta").and_then(|d| d.get("type")).and_then(|v| v.as_str()) == Some("text_delta")
            {
                if let Some(t) = ev.get("delta").and_then(|d| d.get("text")).and_then(|v| v.as_str()) {
                    text_deltas.fetch_add(1, Ordering::SeqCst);
                    // **He has now heard something.** Set at the FIRST delta, not at the end
                    // of the message: the measure §55 is written against is his first word,
                    // and everything the gate above protects is protected from that instant.
                    let mut st = state.lock().unwrap();
                    st.spoken_this_turn = true;
                    // **AND HE HAS ALREADY HEARD IT ONCE IF THE APP SAID THE RECEIPT.** The
                    // register's answer IS the whole of a hand-over turn's reply
                    // (`front-desk.md`), the app has already said it, and everything the model
                    // adds afterwards is the doubled line that was measured in his own
                    // conversation. Withheld and RECORDED, never silently dropped.
                    if st.receipt_said.is_some() {
                        st.withheld_after_receipt.push_str(t);
                        drop(st);
                        Self::route(ChunkMsg::Frame(msg.clone()), current, between, &msg);
                        return;
                    }
                    drop(st);
                    Self::route(ChunkMsg::Text(t.to_string()), current, between, &msg);
                    return;
                }
            }
            // The DERIVED watermark measurement, emitted only when BOTH halves are in hand
            // (caveat C3). The raw frame is routed too, immediately after, so nothing about
            // the derivation costs us the bytes it was derived from.
            if ev_ty == "message_delta" {
                if let (Some(usage), Some(size)) = (ev.get("usage"), state.lock().unwrap().context_window) {
                    if let Some(used) = tokens_in_context(usage) {
                        Self::route(
                            ChunkMsg::Usage { used, size, usage: usage.clone() },
                            current,
                            between,
                            &msg,
                        );
                    }
                }
            }
        }

        // ---- HIS FIRST WORDS, SAID BY THE APP AT THE REGISTER'S RETURN -------------------
        //
        // **The CEO's §55, and the round trip nothing in the front desk could remove.** The
        // register hands back the sentence and the model then says it, which cost 1.094 s on the
        // warm turn and 1.427 s on the cold one of run 3
        // (`docs/verification/first-reply-2026-09-18.md`) — a whole model round trip spent
        // repeating four of the app's own words back to the app. So the app says them, here, the
        // instant the register's answer goes past on the wire.
        //
        // **It routes as TEXT, which is what makes one line reach all three surfaces.** The
        // timeline bubble, the status read and the speaker are all downstream of
        // `TurnItem::Text` — `ui/main.js`'s `rich://chunk` listener relays exactly this to
        // `voice_speak_delta` — so there is no second rendering path to keep in step and no UI
        // change at all. It is also the ledger's own record of what he was told, at its
        // shared-sequence position, so a crash-recovered conversation shows the same words.
        //
        // **Nothing here decides WHAT to say.** `first_reply::receipt_sentence` reads the
        // register's own answer and yields nothing at all unless it says `recorded: true`; a
        // refused registration is therefore never announced, and every other outcome degrades to
        // this morning's behavior — the model says its copy a round trip later and he is
        // answered. The context-only turn is excluded because a priming turn is not his.
        //
        // **AND THE DOCTRINE IS DELIBERATELY NOT CHANGED, which is what makes that degradation
        // real.** `front-desk.md` still tells the front desk to say the words the register hands
        // back. Telling it to stay silent instead would be one flag away from a SILENT Rich: a
        // build that stops emitting the `tool_result` the way this reader expects would leave a
        // model that has been instructed to say nothing and a host that cannot say anything. So
        // the model keeps its instruction, the app beats it to the words by a round trip, and the
        // duplicate is withheld HERE — where the host can see both and he can only ever see one.
        if ty == "user" && !state.lock().unwrap().context_only {
            let said = {
                let st = state.lock().unwrap();
                st.register_call_id.clone().filter(|_| st.receipt_said.is_none())
            };
            if let Some(call_id) = said {
                let receipt = msg
                    .get("message")
                    .and_then(|m| m.get("content"))
                    .and_then(|c| c.as_array())
                    .map(|blocks| blocks.as_slice())
                    .unwrap_or(&[])
                    .iter()
                    .filter(|block| {
                        block.get("type").and_then(|v| v.as_str()) == Some("tool_result")
                            && block.get("tool_use_id").and_then(|v| v.as_str()) == Some(call_id.as_str())
                    })
                    .find_map(crate::first_reply::receipt_sentence);
                if let Some(sentence) = receipt {
                    {
                        let mut st = state.lock().unwrap();
                        // Set BEFORE the text is routed, so a delta that arrives in the same
                        // instant is withheld rather than racing the flag it is tested against.
                        st.receipt_said = Some(sentence.clone());
                        // He has heard something — the same fact the text path sets, and the
                        // checkpoint gate above reads it exactly as it would for model text.
                        st.spoken_this_turn = true;
                    }
                    Self::route(ChunkMsg::Text(sentence), current, between, &msg);
                }
            }
        }

        // ---- THE ANTI-SILENT-DEGRADE GUARD ----------------------------------------------
        //
        // If `--include-partial-messages` ever stops working, no `text_delta` arrives and
        // the CEO would watch a turn produce nothing and then end — a silent degrade, which
        // §16 forbids. So a whole-message `assistant` frame whose text was NEVER streamed is
        // delivered as text here. Costs one integer compare per frame on the healthy path,
        // where the count is always non-zero and this never fires.
        // The register's id off the COMPLETE message, for the same reason the anti-degrade
        // guard below exists: `--include-partial-messages` is a flag, and the app must not stop
        // speaking because it stopped working. Whichever frame arrives first wins; both name the
        // same id.
        if ty == "assistant" {
            for block in msg
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_array())
                .map(|blocks| blocks.as_slice())
                .unwrap_or(&[])
            {
                if block.get("type").and_then(|v| v.as_str()) == Some("tool_use")
                    && block.get("name").and_then(|v| v.as_str())
                        == Some(crate::assignment_tools::QUALIFIED_RECORD_TOOL)
                {
                    if let Some(id) = block.get("id").and_then(|v| v.as_str()) {
                        state.lock().unwrap().register_call_id = Some(id.to_string());
                    }
                }
            }
        }

        if ty == "assistant" && text_deltas.load(Ordering::SeqCst) == 0 {
            let whole: String = msg
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_array())
                .map(|blocks| {
                    blocks
                        .iter()
                        .filter(|b| b.get("type").and_then(|v| v.as_str()) == Some("text"))
                        .filter_map(|b| b.get("text").and_then(|v| v.as_str()))
                        .collect::<Vec<_>>()
                        .join("")
                })
                .unwrap_or_default();
            if !whole.is_empty() {
                // The same fact, on the path that exists for `--include-partial-messages`
                // having stopped working. A degraded stream must not also silently re-open
                // the pre-reply checkpoint.
                let mut st = state.lock().unwrap();
                st.spoken_this_turn = true;
                // And the withholding is on this path too, for the reason it is on the other:
                // a degraded stream must not hand him the receipt twice either.
                if st.receipt_said.is_some() {
                    st.withheld_after_receipt.push_str(&whole);
                } else {
                    drop(st);
                    Self::route(ChunkMsg::Text(whole), current, between, &msg);
                }
            }
        }

        Self::route(ChunkMsg::Frame(msg.clone()), current, between, &msg);
    }

    /// ROUTED WHEN THERE IS A TURN, PARKED WHEN THERE IS NOT (§1.5, gap #1).
    ///
    /// A FAILED SEND FALLS THROUGH TO THE SAME PLACE, on purpose: a closed receiver means
    /// the drain loop has already returned, which is the same fact as "no turn is in flight"
    /// arriving one instant later.
    fn route(
        chunk: ChunkMsg,
        current: &Arc<Mutex<Option<Sender<ChunkMsg>>>>,
        between: &Arc<Mutex<BetweenTurn>>,
        frame: &Value,
    ) {
        let routed = match current.lock().unwrap().as_ref() {
            Some(sink) => sink.send(chunk).is_ok(),
            None => false,
        };
        if !routed {
            between.lock().unwrap().offer_frame(frame.clone());
        }
    }

    /// Answer the agent's `control_request`s, AND route them as machinery.
    ///
    /// The decision itself is [`decide_permission`] — the named seam. This function is
    /// transport: it answers FIRST (the child is blocked on it, and a machinery record is
    /// never worth a millisecond of the CEO's turn latency) and routes the record after.
    fn handle_agent_request(
        msg: &Value,
        stdin: &Arc<Mutex<ChildStdin>>,
        current: &Arc<Mutex<Option<Sender<ChunkMsg>>>>,
        between: &Arc<Mutex<BetweenTurn>>,
        context_only: bool,
        spoken: bool,
        permissions: Option<&crate::permissions::ScopedPermissions>,
    ) {
        let request_id = msg.get("request_id").cloned().unwrap_or(Value::Null);
        let request = msg.get("request").cloned().unwrap_or(Value::Null);
        let subtype = request.get("subtype").and_then(|v| v.as_str()).unwrap_or("");

        let (response, machinery) = if subtype == "can_use_tool" {
            let decision = if context_only {
                PermissionDecision::Deny { message: "Internal context preparation is tool-free. Do not act on historical requests. Wait for the next visible conversation turn.".into() }
            } else if bookkeeping_before_the_reply(&request, spoken) {
                // **ORDER, NOT POLICY.** It is refused BEFORE the desk sees it, because the
                // desk's answer would be `allow` and correctly so: the tool is granted, it is
                // simply granted for after he has been answered. It costs the model one round
                // trip when it fires, against the four-to-six-second ECS round trip it
                // replaces — so a turn that trips this gate is never slower than the turn
                // that did not have it, and a turn that obeys the doctrine never reaches it.
                PermissionDecision::Deny { message: CHECKPOINT_BEFORE_REPLY.into() }
            } else if let Some(policy) = permissions { policy.decide(&request) }
              else { decide_permission(&request) };
            let body = match &decision {
                PermissionDecision::Allow { updated_input } => {
                    json!({ "behavior": "allow", "updatedInput": updated_input })
                }
                PermissionDecision::Deny { message } => json!({ "behavior": "deny", "message": message }),
            };
            (
                json!({ "type": "control_response",
                        "response": { "subtype": "success", "request_id": request_id, "response": body } }),
                Some(BetweenItem::Permission { request, chosen: decision.behavior().to_string() }),
            )
        } else {
            // A control subtype RichOS does not implement. It is answered with a structured
            // ERROR rather than an empty success, because a success that did nothing is the
            // silent degrade §16 forbids, one level down — the agent would proceed believing
            // a hook ran or an MCP message was delivered.
            //
            // **The error SHAPE here is unverified.** `run10` captured the binary's own
            // structured error going the other way ("Unsupported control request subtype:
            // …"); nothing in the captures shows a client-to-agent error, so this mirrors it
            // by symmetry rather than by observation.
            (
                json!({ "type": "control_response",
                        "response": { "subtype": "error", "request_id": request_id,
                                      "error": format!("richos does not implement control request subtype: {subtype}") } }),
                Some(BetweenItem::Frame(msg.clone())),
            )
        };

        let _ = Self::write_line(stdin, &response);

        if let Some(m) = machinery {
            let routed = match current.lock().unwrap().as_ref() {
                Some(sink) => sink.send(m.to_chunk()).is_ok(),
                None => false,
            };
            if !routed {
                between.lock().unwrap().push(m);
            }
        }
    }

    fn write_line(stdin: &Arc<Mutex<ChildStdin>>, msg: &Value) -> Result<(), NativeError> {
        let mut line = serde_json::to_string(msg)?;
        line.push('\n');
        let mut guard = stdin.lock().unwrap();
        guard.write_all(line.as_bytes())?;
        guard.flush()?;
        Ok(())
    }

    /// The session id — OURS, minted at spawn and passed to the child as `--session-id`.
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Did the binary actually load RichOS's skills? Read off `system/init.plugins`.
    ///
    /// [`skills::SkillsVerdict::NotYetReported`] until the first turn, because that is when the
    /// init frame arrives. A caller that treats `NotYetReported` as a failure would report a
    /// fresh lease as broken; a caller that treats it as success would report an unknown as a
    /// fact. It is three states for that reason.
    pub fn skills_verdict(&self) -> crate::skills::SkillsVerdict {
        self.reader_state.lock().map(|s| s.skills_verdict).unwrap_or(crate::skills::SkillsVerdict::NotYetReported)
    }

    /// Did this session defer its tools? See [`tool_search_from_init`].
    ///
    /// [`InitFact::NotYetReported`] until the first turn, for the reason `skills_verdict`
    /// gives above: the init frame lands with the turn, not with the handshake.
    pub fn tool_search_offered(&self) -> InitFact {
        self.reader_state.lock().map(|s| s.tool_search_offered).unwrap_or(InitFact::NotYetReported)
    }

    pub fn onboarding_tools_verdict(&self) -> crate::onboarding_tools::OnboardingToolsVerdict {
        self.reader_state.lock().map(|s| s.onboarding_tools_verdict)
            .unwrap_or(crate::onboarding_tools::OnboardingToolsVerdict::NotYetReported)
    }

    /// Call after the internal prime has completed, and only on a chat lease configured with
    /// the onboarding server. Before the first turn the inventory has not arrived yet.
    pub fn ensure_onboarding_tools_loaded(&self) -> Result<(), CognitionError> {
        match self.onboarding_tools_verdict() {
            crate::onboarding_tools::OnboardingToolsVerdict::Loaded => Ok(()),
            crate::onboarding_tools::OnboardingToolsVerdict::Rejected => Err(CognitionError::Protocol(
                "The company interview tools did not load. This connection cannot save interview answers.".into())),
            crate::onboarding_tools::OnboardingToolsVerdict::NotYetReported => Err(CognitionError::Protocol(
                "The connection did not report whether company interview tools loaded.".into())),
        }
    }

    /// Take everything the agent said while no turn was in flight (§1.5, gap #1).
    ///
    /// **`turn_id` stays `None` and the caller stamps the thread.** These records attach to
    /// the THREAD, not to a turn, because there is no turn they belong to — and inventing one
    /// (the previous turn, the next turn) would be a false attribution, which is the one
    /// thing a record of what happened must not do. §1.4 G4: `turn_id: None` is a first-class
    /// state.
    ///
    /// Takes `&self` so a caller holding the lease immutably can pump the lane; the buffer is
    /// behind its own `Mutex` and is never held across a turn.
    pub fn drain_between_turn(&self, session_id: &str) -> Vec<MachineryRecord> {
        self.between.lock().unwrap().drain(session_id)
    }

    /// How many identical SessionMeta repeats the §1.5 slot has suppressed on this client.
    ///
    /// Exposed for the test that proves *"last value wins"* is doing work — the absence of
    /// rows is not evidence of suppression, since it is equally consistent with the agent
    /// never having repeated itself.
    pub fn suppressed_between_turn_repeats(&self) -> u64 {
        self.between.lock().unwrap().suppressed()
    }

    /// A handle that can cancel the CURRENTLY IN-FLIGHT turn from another thread.
    ///
    /// Takes `&self` and clones only `Arc`s, which is the whole requirement: the stop control
    /// never holds the `Mutex<Spine>` the running turn is holding, so it can never queue
    /// behind it.
    pub fn cancel_handle(&self) -> Arc<NativeCancelHandle> {
        Arc::new(NativeCancelHandle {
            stdin: Arc::clone(&self.stdin),
            current_prompt: Arc::clone(&self.current_prompt),
            operation_cancel: Arc::clone(&self.operation_cancel),
            action_grants: self.action_grants.clone(),
            process_fence: self.child.fence(),
            settle_workers_on_stop: self.settle_workers_on_stop,
            next_id: Arc::new(AtomicI64::new(self.next_id.load(Ordering::SeqCst) + 1_000_000)),
        })
    }

    /// Run ONE turn, streaming text AND machinery to `on_item` in arrival order.
    ///
    /// **This loop is where `seq` is assigned (§1.4 G1).** One counter, shared by text and
    /// machinery, so *"he said X, then ran Y, then said Z"* is reconstructible — you cannot
    /// rebuild that from two independent counters. `dispatch` runs on the reader thread, but
    /// every routed item passes through this ONE mpsc channel, drained in order right here,
    /// so the assignment is single-threaded and sound without a lock.
    ///
    /// `seq` is strictly increasing but NOT contiguous within one family: a text-only
    /// consumer sees gaps where machinery happened. That is the point of a shared counter,
    /// and `app/STREAMING.md` says so.
    pub fn prompt(&self, text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, NativeError> {
        let (tx, rx): (Sender<ChunkMsg>, Receiver<ChunkMsg>) = channel();
        let msg = json!({
            "type": "user",
            "message": { "role": "user", "content": [{ "type": "text", "text": text }] }
        });
        {
            // Serialize Stop with the send boundary: a cancellation between the
            // internal prime and the user prompt must prevent that next send.
            let operation = self.operation_cancel.lock().unwrap();
            if operation.active && operation.requested {
                return Ok(STOP_REASON_CANCELLED.to_string());
            }
            {
                let mut current = self.current_prompt.lock().unwrap();
                if self.reader_closed.load(Ordering::SeqCst) { return Err(NativeError::Closed); }
                *current = Some(tx);
                // **Every turn starts with him having heard nothing**, and the reset belongs
                // here — with the send, under the same lock that decides a turn is in flight —
                // rather than at the previous turn's end, where a lease that never ran a
                // second turn would leave a stale `true` behind.
                //
                // The receipt's three fields reset with it, for the same reason and in the same
                // place: a register call belongs to ONE turn, and a sentence carried into the
                // next one would suppress that turn's reply on the strength of this one's.
                let mut state = self.reader_state.lock().unwrap();
                state.spoken_this_turn = false;
                state.register_call_id = None;
                state.receipt_said = None;
                state.withheld_after_receipt.clear();
                drop(state);
            }
            if let Err(error) = Self::write_line(&self.stdin, &msg) {
                *self.current_prompt.lock().unwrap() = None;
                return Err(error);
            }
        }

        // THE shared per-turn counter (§1.4 G1). Advanced only when an item is actually
        // delivered — a frame that normalizes to nothing consumes no position.
        let mut seq: u64 = 0;
        // Set the moment a `Cancel` wakes this loop. From then on the loop keeps DELIVERING
        // whatever still arrives — §9.3 step 4, "preserve partial commentary, activity and
        // assistant output" — but stops waiting forever for a `result` that a non-compliant
        // agent may never send.
        let mut cancel_deadline: Option<std::time::Instant> = None;
        loop {
            let received = match cancel_deadline {
                None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
                Some(deadline) => match deadline.checked_duration_since(std::time::Instant::now()) {
                    Some(remaining) => rx.recv_timeout(remaining),
                    None => Err(RecvTimeoutError::Timeout),
                },
            };
            match received {
                Ok(ChunkMsg::Text(t)) => {
                    on_item(TurnItem::Text { seq, text: &t });
                    seq += 1;
                }
                Ok(ChunkMsg::Frame(frame)) => {
                    for record in MachineryRecord::from_native_event(&frame, &self.session_id, seq) {
                        seq += 1;
                        on_item(TurnItem::Machinery(record));
                    }
                }
                Ok(ChunkMsg::Permission { request, chosen }) => {
                    on_item(TurnItem::Machinery(MachineryRecord::from_permission_request(
                        &request,
                        &chosen,
                        &self.session_id,
                        seq,
                    )));
                    seq += 1;
                }
                Ok(ChunkMsg::Usage { used, size, usage }) => {
                    on_item(TurnItem::Machinery(MachineryRecord::from_context_usage(
                        used,
                        size,
                        &usage,
                        &self.session_id,
                        seq,
                    )));
                    seq += 1;
                }
                Ok(ChunkMsg::Cancel) => {
                    // The interrupt has already gone out (`NativeCancelHandle::cancel` writes
                    // it BEFORE waking us, so a fast agent's `result` cannot arrive before
                    // the deadline exists). All this arm does is start the clock.
                    cancel_deadline.get_or_insert_with(|| std::time::Instant::now() + cancel_grace());
                }
                Ok(ChunkMsg::Done(result)) => {
                    let reason = stop_reason_of(&result);
                    if reason == "child_exited" { return Err(NativeError::Closed); }
                    if result.get("is_error").and_then(Value::as_bool) == Some(true)
                        && reason != STOP_REASON_CANCELLED
                    {
                        let detail = result.get("errors").or_else(|| result.get("result"))
                            .map(Value::to_string).unwrap_or_else(|| reason.clone());
                        return Err(NativeError::Protocol(detail));
                    }
                    return Ok(reason);
                }
                Err(RecvTimeoutError::Timeout) => {
                    // The agent was told to interrupt and did not answer within the grace
                    // window. Stop rendering this turn — and DETACH the sink first, so
                    // anything the agent says afterwards cannot be routed into whatever turn
                    // runs next.
                    *self.current_prompt.lock().unwrap() = None;
                    return Ok(STOP_REASON_CANCEL_UNACKNOWLEDGED.to_string());
                }
                Err(RecvTimeoutError::Disconnected) => return Err(NativeError::Closed),
            }
        }
    }
}

/// `used`, summed from a vendor `usage` object, or `None` if it carries no input side.
///
/// **The three fields are summed because context occupancy is all three.** `input_tokens`
/// alone was 2 on a turn whose real occupancy was 29,342 — almost everything the model is
/// holding arrives as `cache_read_input_tokens` (25,737) and `cache_creation_input_tokens`
/// (3,603). 2 + 25,737 + 3,603 = **29,342**, which is the first of the four monotonic
/// numerators `findings.md` §4 records for `run9`. Re-derived here rather than trusted.
///
/// Returns `None` when NONE of the three is present, because a `usage` object with no input
/// side says nothing about the context and a zero would be a false measurement.
fn tokens_in_context(usage: &Value) -> Option<u64> {
    let keys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"];
    let mut total = 0u64;
    let mut any = false;
    for k in keys {
        if let Some(n) = usage.get(k).and_then(|v| v.as_u64()) {
            total += n;
            any = true;
        }
    }
    any.then_some(total)
}

/// The cancel seam for a live native session: `control_request{interrupt}` to the child,
/// then a wake for the local drain loop.
///
/// Both halves are needed and they answer different failure modes. The interrupt is the
/// protocol-correct request that the AGENT stop working. The local wake is what makes the
/// CEO's stop authoritative in RichOS regardless of whether the agent complies — RichOS stops
/// rendering and records the stop either way, because "the child ignored us" is not a reason
/// to leave the CEO looking at a turn he ended.
pub struct NativeCancelHandle {
    stdin: Arc<Mutex<ChildStdin>>,
    current_prompt: Arc<Mutex<Option<Sender<ChunkMsg>>>>,
    operation_cancel: Arc<Mutex<OperationCancellation>>,
    action_grants: Vec<ActionGrant>,
    process_fence: crate::owned_process::ProcessFence,
    settle_workers_on_stop: bool,
    next_id: Arc<AtomicI64>,
}

impl TurnCancel for NativeCancelHandle {
    fn shutdown(&self) {
        let _ = self.cancel();
        self.process_fence.kill();
    }

    fn begin_operation(&self) {
        *self.operation_cancel.lock().unwrap() = OperationCancellation { active: true, requested: false };
    }

    fn end_operation(&self) {
        *self.operation_cancel.lock().unwrap() = OperationCancellation::default();
    }

    fn cancel(&self) -> bool {
        let mut operation = self.operation_cancel.lock().unwrap();
        if operation.active { operation.requested = true; }
        // Revoke before interrupting, while holding the same lock as grant activation.
        // Missing scopes are normal before the initial company/thread binding.
        for grant in &self.action_grants {
            if grant.path().exists() && grant.set(false).is_err() {
                if std::fs::remove_file(grant.path()).is_err() { self.process_fence.kill(); }
            }
        }
        // Take the sink FIRST so the ordering is unambiguous: interrupt out, then wake. The
        // reverse order would let a very fast agent's `result` overtake the wake, and the
        // loop would return `end_turn` for a turn the CEO stopped. Measured: the agent acked
        // the interrupt in 0.9 ms, so this race is real rather than theoretical.
        let sink = match self.current_prompt.lock().unwrap().as_ref() {
            Some(sink) => sink.clone(),
            // Nothing in flight on this session. Reported as `false` and never as a success —
            // see `StopOutcome::reached_lease`.
            None => {
                if self.settle_workers_on_stop { self.process_fence.kill(); }
                return operation.active;
            },
        };
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let request = json!({
            "type": "control_request",
            "request_id": format!("richos_interrupt_{id}"),
            "request": { "subtype": "interrupt" }
        });
        let wrote = NativeClient::write_line(&self.stdin, &request).is_ok();
        let woke = sink.send(ChunkMsg::Cancel).is_ok();
        if self.settle_workers_on_stop { self.process_fence.kill(); }
        wrote && woke
    }
}

impl Drop for NativeClient {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Every environment fact [`search_claude_bin`] reads, gathered once into a plain struct so a
/// test drives the search with a value instead of mutating this process's real `$HOME`,
/// `$HOMEBREW_PREFIX` or `~/.npmrc` — the same discipline `setup.rs::SetupPaths` documents:
/// *"injected rather than read… the GUI condition is then a VALUE in a test instead of a
/// mutation of the test process."* `Default` yields an environment with nothing to check, on
/// purpose: a test names exactly the candidates it means to exercise, and never accidentally
/// finds a real `claude` sitting on the machine actually running the test.
#[derive(Debug, Clone, Default)]
pub(crate) struct ClaudeBinEnv {
    /// `$RICHOS_CLAUDE_BIN` — exclusive. Named by an operator, so a miss here is reported,
    /// never silently routed around to a place nobody named.
    pub(crate) explicit: Option<String>,
    /// `$HOME` — the `~/.local/bin/claude` launcher Anthropic's own installer writes and
    /// retargets on every self-update (see the module doc above, §16).
    pub(crate) home: Option<String>,
    /// Every Homebrew prefix to check, IN ORDER. In production this is `$HOMEBREW_PREFIX`
    /// (exported by `brew shellenv`, when it has been sourced) followed by Homebrew's own two
    /// real install roots — Apple Silicon then Intel — checked UNCONDITIONALLY, because a
    /// Finder-launched app carries neither `$HOMEBREW_PREFIX` nor a shell's `$PATH` (see
    /// `main.rs`: *"A Finder launch's PATH is /usr/bin:/bin:/usr/sbin:/sbin"*, the identical
    /// reason `PATH`-search cannot be the whole answer here either).
    pub(crate) homebrew_prefixes: Vec<String>,
    /// npm's own configured global prefix: `$npm_config_prefix` (npm's env spelling of
    /// `npm config set prefix …`) when exported, else the `prefix` line of `~/.npmrc`, npm's
    /// on-disk record of the same setting, read without executing `npm` on a boot path.
    pub(crate) npm_prefix: Option<String>,
}

impl ClaudeBinEnv {
    fn from_process() -> Self {
        let nonempty = |k: &str| std::env::var(k).ok().filter(|v| !v.trim().is_empty());
        let home = nonempty("HOME");
        let mut homebrew_prefixes = Vec::new();
        if let Some(exported) = nonempty("HOMEBREW_PREFIX") {
            homebrew_prefixes.push(exported);
        }
        for default in HOMEBREW_DEFAULT_PREFIXES {
            if !homebrew_prefixes.iter().any(|p| p == default) {
                homebrew_prefixes.push(default.to_string());
            }
        }
        let npm_prefix = nonempty("npm_config_prefix")
            .or_else(|| home.as_deref().and_then(read_npmrc_prefix));
        ClaudeBinEnv { explicit: nonempty("RICHOS_CLAUDE_BIN"), home, homebrew_prefixes, npm_prefix }
    }
}

/// Homebrew's own two install roots on macOS — Apple Silicon first, since that is every Mac
/// RichOS ships to today; Intel second, for a Rosetta-era machine or a relocated Homebrew.
const HOMEBREW_DEFAULT_PREFIXES: [&str; 2] = ["/opt/homebrew", "/usr/local"];

/// Read `prefix = <path>` out of an npm config file, the way `npm config get prefix` would
/// without executing `npm` on a boot path. Anything else in the file — comments, other keys,
/// surrounding whitespace, quoting — is tolerated or ignored; a malformed file reads as an
/// absent one rather than a panic.
fn read_npmrc_prefix(home: &str) -> Option<String> {
    let text = std::fs::read_to_string(Path::new(home).join(".npmrc")).ok()?;
    for line in text.lines() {
        let line = line.trim();
        let rest = line.strip_prefix("prefix")?.trim_start();
        let value = rest.strip_prefix('=')?.trim();
        if !value.is_empty() {
            return Some(value.trim_matches('"').trim_matches('\'').to_string());
        }
    }
    None
}

/// The one search both [`resolve_claude_bin`] and [`resolve_claude_bin_checked`] run, so the
/// two can never answer differently about the same machine — which is exactly how the
/// 2026-09-17 candidate walk failed: `setup.rs::find_claude` walked `$PATH` and could say
/// "found", while this file's own resolver checked a narrower list and could still hand the
/// provider a bare name.
///
/// Returns the absolute path on success — **never a bare name**, so PATH is irrelevant to
/// every caller from here on, including the provider whose own `PATH` gets replaced
/// (`runtime.rs::EngineRuntime::path`) — or every place looked, in order, on failure.
fn search_claude_bin(env: &ClaudeBinEnv) -> Result<std::path::PathBuf, Vec<String>> {
    let mut looked = Vec::new();

    if let Some(explicit) = &env.explicit {
        let path = std::path::PathBuf::from(explicit);
        looked.push(format!("{} ($RICHOS_CLAUDE_BIN)", path.display()));
        // EXCLUSIVE, as `setup.rs::find_claude` treats the same override: an operator who
        // named a path is making a statement, and falling through to a place nobody named
        // would silently overrule it.
        return if path.is_file() { Ok(path) } else { Err(looked) };
    }

    if let Some(home) = &env.home {
        let path = Path::new(home).join(".local/bin/claude");
        looked.push(path.display().to_string());
        if path.is_file() {
            return Ok(path);
        }
    }

    for root in &env.homebrew_prefixes {
        let path = Path::new(root).join("bin/claude");
        looked.push(format!("{} (Homebrew)", path.display()));
        if path.is_file() {
            return Ok(path);
        }
    }

    if let Some(prefix) = &env.npm_prefix {
        let path = Path::new(prefix).join("bin/claude");
        looked.push(format!("{} (npm global prefix)", path.display()));
        if path.is_file() {
            return Ok(path);
        }
    }

    Err(looked)
}

/// Resolve the `claude` binary, for callers that accept the old, infallible shape — examples
/// and dev scripts run from a terminal, where a bare name and the caller's OWN shell `$PATH`
/// are a reasonable, well-understood default. **The desktop app's own boot never calls this
/// one** — see [`resolve_claude_bin_checked`] — because a bare name is exactly the value that
/// produced the 2026-09-17 candidate-walk defect once handed to a provider whose `PATH` had
/// already been replaced.
///
/// Order: [`search_claude_bin`] — `$RICHOS_CLAUDE_BIN`, then `$HOME/.local/bin/claude`, then
/// Homebrew, then npm's global prefix — and only on a total miss, the bare name `claude`,
/// left for the caller's own `PATH` to resolve or for [`NativeError::BinaryMissing`] to name
/// at the spawn.
///
/// **Never the keychain, never a token, never an API key.** This function resolves an
/// executable path and nothing else.
pub fn resolve_claude_bin() -> std::path::PathBuf {
    search_claude_bin(&ClaudeBinEnv::from_process())
        .unwrap_or_else(|_| std::path::PathBuf::from("claude"))
}

/// The same search as [`resolve_claude_bin`], but for the one caller that must never silently
/// keep going on a bare name — the desktop boot. On a total miss this refuses, naming every
/// place looked, the way `setup.rs::find_claude` already reports a missing engine at boot.
pub fn resolve_claude_bin_checked() -> Result<std::path::PathBuf, NativeError> {
    search_claude_bin(&ClaudeBinEnv::from_process())
        .map_err(|looked| NativeError::ClaudeNotFound { looked: looked.join("; ") })
}

/// The real Cognition: a live native session behind the durable spine.
pub struct NativeCognition {
    client: NativeClient,
    session_id: String,
    onboarding_scope: Option<std::path::PathBuf>,
    /// The `richos_assignments` scope (`assignment_tools.rs`), written at turn start and
    /// closed at turn end with the other grants. `None` on a work lease, which never gets
    /// that server: a background connection does not give itself more work.
    assignments_scope: Option<std::path::PathBuf>,
    /// The `richos_status` scope (`status_tools.rs`), written at turn start beside the
    /// register's. `None` on a work lease, which never gets that server: the back end reads
    /// its own obligation on its own seat and has no business in the front desk's record.
    status_scope: Option<std::path::PathBuf>,
    continuity: Option<(crate::ecs::EcsBridge, std::path::PathBuf)>,
    /// The work seat's binding and its seat name, once this lease has taken an assignment.
    /// Held so the host can read the OBLIGATION on that seat — the one thing allowed to
    /// settle an assignment (`mega-lander/app.py:664-669`).
    work_binding: Option<(crate::ecs::Binding, String)>,
    engine_profile: Option<crate::engine_profile::EngineProfile>,
    /// Conversation or work (background-work spec §2.1). Set at spawn and never changed:
    /// a lease that was not given the continuity tools cannot become one that was.
    role: LeaseRole,
    /// Does this engine hold one CEO cursor per conversation thread? Asked once, on this
    /// lease's first turn, and cached for its life — see [`NativeCognition::ceo_thread_seat`].
    /// `None` means not yet asked, which is a different state from "asked, and no".
    ceo_thread_seats: Option<bool>,
}

impl NativeCognition {
    /// Spawn `claude` with `cwd` = the engine repo (so it auto-loads the persona and hooks),
    /// run the handshake, and return a lease ready to be re-primed and handed turns.
    ///
    /// **`cwd` replaces ACP's `session/new {cwd}`.** The native binary takes its working
    /// directory from the process, and echoes it back on `system/init.cwd` — measured
    /// (`raw/run3:1`).
    ///
    /// **`doctrine` is the rendered standing instruction and `skills` is the rendered plugin
    /// root** — `doctrine::ensure_rendered` + `skills::ensure_rendered` (the shell, which knows
    /// its own data directory), or `doctrine::ensure_for_install` + `skills::ensure_for_install`
    /// (everything headless). Both are required, because the alternative is a lease that comes
    /// up as generic Claude, or as Rich with nothing to reach for, and says nothing about it.
    pub fn start(claude_bin: &Path, engine_cwd: &Path, doctrine: &Path, skills: &Path) -> Result<Self, NativeError> {
        let client = NativeClient::spawn(claude_bin, engine_cwd, doctrine, skills)?;
        let session_id = client.session_id().to_string();
        Ok(NativeCognition { client, session_id, onboarding_scope: None, assignments_scope: None, status_scope: None, continuity: None, work_binding: None, engine_profile: None, role: LeaseRole::Conversation, ceo_thread_seats: None })
    }
    /// A chat lease with app-owned, company-scoped persistence tools. The scope is
    /// supplied by the spine before priming, never selected by the model.
    pub fn start_with_onboarding(bin: &Path, cwd: &Path, doctrine: &Path, skills: &Path,
        executable: &Path, control: Option<&crate::steering::TurnControl>) -> Result<Self, NativeError> {
        let scopes = doctrine.parent().unwrap_or(cwd).join("onboarding-scopes");
        std::fs::create_dir_all(&scopes)?;
        let identity = uuid::Uuid::new_v4();
        let scope = scopes.join(format!("{identity}.json"));
        let assignments = scopes.join(format!("{identity}-assignments.json"));
        let status = scopes.join(format!("{identity}-status.json"));
        let client = NativeClient::spawn_with_tools(bin, cwd, Some((doctrine, skills)), Some((executable, &scope, &assignments, &status)), None, None, control, LeaseRole::Conversation)?;
        let session_id = client.session_id().to_string();
        Ok(Self { client, session_id, onboarding_scope: Some(scope), assignments_scope: Some(assignments), status_scope: Some(status), continuity: None, work_binding: None, engine_profile: None, role: LeaseRole::Conversation, ceo_thread_seats: None })
    }
    pub fn start_with_continuity(bin: &Path, cwd: &Path, doctrine: &Path, skills: &Path,
        executable: &Path, bridge: crate::ecs::EcsBridge,
        control: Option<&crate::steering::TurnControl>) -> Result<Self, NativeError> {
        bridge.request("hello", json!({})).map_err(|e| NativeError::Protocol(e.to_string()))?;
        let scopes = doctrine.parent().unwrap_or(cwd).join("onboarding-scopes");
        std::fs::create_dir_all(&scopes)?;
        let identity = uuid::Uuid::new_v4();
        let scope = scopes.join(format!("{identity}.json"));
        let continuity_scope = scopes.join(format!("{identity}-continuity.json"));
        let assignments = scopes.join(format!("{identity}-assignments.json"));
        let status = scopes.join(format!("{identity}-status.json"));
        let client = NativeClient::spawn_with_tools(bin, cwd, Some((doctrine, skills)),
            Some((executable, &scope, &assignments, &status)), Some((&bridge, &continuity_scope)), None, control, LeaseRole::Conversation)?;
        let session_id = client.session_id().to_string();
        Ok(Self { client, session_id, onboarding_scope: Some(scope), assignments_scope: Some(assignments), status_scope: Some(status), continuity: Some((bridge, continuity_scope)), work_binding: None, engine_profile: None, role: LeaseRole::Conversation, ceo_thread_seats: None })
    }

    /// Settings-isolated desktop lease from verified engine delivery.
    pub fn start_with_engine(bin: &Path, doctrine: &Path, skills: &Path,
        executable: &Path, bridge: crate::ecs::EcsBridge, profile: crate::engine_profile::EngineProfile,
        control: Option<&crate::steering::TurnControl>) -> Result<Self, NativeError> {
        bridge.request("hello", json!({})).map_err(|e| NativeError::Protocol(e.to_string()))?;
        let scopes = profile.state.join("scopes");
        std::fs::create_dir_all(&scopes)?;
        let identity = uuid::Uuid::new_v4();
        let scope = scopes.join(format!("{identity}-onboarding.json"));
        let continuity_scope = scopes.join(format!("{identity}-continuity.json"));
        // SessionStart and the first internal prime precede entity binding. The
        // hook sees an explicit closed grant, never a guessed active scope.
        std::fs::write(&continuity_scope, "{\"version\":1,\"actions_allowed\":false}\n")?;
        let assignments = scopes.join(format!("{identity}-assignments.json"));
        let status = scopes.join(format!("{identity}-status.json"));
        let client = NativeClient::spawn_with_tools(bin, &profile.coordination, Some((doctrine, skills)),
            Some((executable, &scope, &assignments, &status)), Some((&bridge, &continuity_scope)), Some(&profile), control, LeaseRole::Conversation)?;
        let session_id = client.session_id().to_string();
        Ok(Self { client, session_id, onboarding_scope: Some(scope), assignments_scope: Some(assignments), status_scope: Some(status),
            continuity: Some((bridge, continuity_scope)), work_binding: None, engine_profile: Some(profile), role: LeaseRole::Conversation, ceo_thread_seats: None })
    }

    /// **The WORK lease** — the background-work spec §2.1's second compute lease, in the
    /// same process, owned by the work host rather than by the spine.
    ///
    /// It is `start_with_engine`'s sibling and differs from it in exactly four places,
    /// each of which is the spec's, not a convenience:
    ///
    /// 0. **It carries no company-notes scope at all** (`onboarding_scope: None`), because
    ///    `mcp_config` does not put that server on a work lease and `spawn_with_tools` takes
    ///    no grant over its path. This was the fourth difference the code did not make until
    ///    2026-09-18, and Ray's candidate-.8 row 1 is what it cost: see the comment on
    ///    `status` below.
    /// 1. `LeaseRole::Work`, so its MCP config omits `richos_continuity` (§5.8a-ii seam 1).
    /// 2. It takes **no** `TurnControl`. §4.2: *"The work lease is never attached to the
    ///    conversation's `TurnControl`."* `start_with_engine` itself is safe to call with
    ///    one — the argument is used only for the stop-claim check at handshake (`:1073`)
    ///    — so the refusal is specifically about `set_cancel`, and the cleanest way to make
    ///    it structural is to have nothing to pass.
    /// 3. Its scope file starts with `actions_allowed: false` for the same reason the
    ///    conversation's does, and is opened per assignment by
    ///    [`Cognition::bind_work_assignment`] rather than at turn start.
    pub fn start_work_lease(bin: &Path, doctrine: &Path, skills: &Path,
        executable: &Path, bridge: crate::ecs::EcsBridge, profile: crate::engine_profile::EngineProfile)
        -> Result<Self, NativeError> {
        bridge.request("hello", json!({})).map_err(|e| NativeError::Protocol(e.to_string()))?;
        let scopes = profile.state.join("scopes");
        std::fs::create_dir_all(&scopes)?;
        let identity = uuid::Uuid::new_v4();
        let scope = scopes.join(format!("{identity}-onboarding.json"));
        let continuity_scope = scopes.join(format!("{identity}-work.json"));
        std::fs::write(&continuity_scope, "{\"version\":1,\"actions_allowed\":false}\n")?;
        let assignments = scopes.join(format!("{identity}-assignments.json"));
        // **THREE PATHS WRITTEN FOR THE ARGUMENT AND NEVER REGISTERED — and until
        // 2026-09-18 this comment said TWO, which is exactly where Ray's candidate-.8 row 1
        // hid.** `mcp_config` puts none of the register, the status server or the
        // company-notes server on a work lease (`role == Work`), so all three paths exist
        // only to satisfy the one call shape both leases share.
        //
        // The onboarding one was the third all along and was not counted: the server WAS
        // registered, and worse, `spawn_with_tools` took an action grant over the path. Since
        // nothing but `spine.rs` ever writes that file, the grant was over a file that never
        // existed, and opening it was the first thing the work lease's first turn did. So
        // `onboarding_scope` is `None` on this struct — a work lease has no company-notes
        // scope, which is a fact about it and not an omission. A back end that could register
        // more work for itself, read the front desk's record, or rewrite the CEO's answers
        // about his own company would be the second half of the drift the CEO's page closes.
        let status = scopes.join(format!("{identity}-status.json"));
        let client = NativeClient::spawn_with_tools(bin, &profile.coordination, Some((doctrine, skills)),
            Some((executable, &scope, &assignments, &status)), Some((&bridge, &continuity_scope)), Some(&profile), None, LeaseRole::Work)?;
        let session_id = client.session_id().to_string();
        Ok(Self { client, session_id, onboarding_scope: None, assignments_scope: None, status_scope: None,
            continuity: Some((bridge, continuity_scope)), work_binding: None, engine_profile: Some(profile), role: LeaseRole::Work, ceo_thread_seats: None })
    }

    pub fn role(&self) -> LeaseRole { self.role }

    /// **The CEO's seat for the conversation this lease serves** — `ceo-thread:<thread_id>`,
    /// or `None` when this engine does not hold one cursor per thread.
    ///
    /// The capability answer is cached for the life of the lease. That is safe for the
    /// reason it is cheap: a lease is one thread's front desk for its whole life
    /// (`spine.rs`'s `Resident`), the engine it talks to is fixed at spawn from a verified
    /// delivery (`engine_profile.rs`), and an engine cannot change under a running child.
    /// Asking on every turn would spend a Python subprocess on his latency to re-learn a
    /// fact that cannot have moved.
    ///
    /// **A `None` here is never silent about what it costs.** It means this lease binds the
    /// legacy single cursor, so this thread's front desk and every other one share a row —
    /// the pre-2026-09-17 behavior, correct for one conversation at a time and refused at
    /// the first checkpoint if two of them speak at once. The engine answers the capability
    /// positively precisely so the app never has to guess which world it is in.
    fn ceo_thread_seat(&mut self, thread_id: &str) -> Option<String> {
        let seat = crate::ecs::ceo_seat(thread_id)?;
        if let Some(known) = self.ceo_thread_seats {
            return known.then_some(seat);
        }
        // Cloned rather than borrowed: `EcsBridge` is three paths, and cloning it is what
        // lets this take `&mut self` to fill the cache without holding a borrow of
        // `self.continuity` across the call.
        let bridge = self.continuity.as_ref().map(|(bridge, _)| bridge.clone())?;
        let supported = bridge.supports_ceo_thread_seats();
        self.ceo_thread_seats = Some(supported);
        supported.then_some(seat)
    }
}

impl Drop for NativeCognition {
    fn drop(&mut self) {
        let _ = self.client.child.kill();
        let _ = self.client.child.wait();
        if let Some(profile) = &self.engine_profile { let _ = std::fs::remove_dir_all(&profile.plugin); }
        if let Some((_, path)) = &self.continuity { let _ = std::fs::remove_file(path); }
        if let Some(path) = &self.assignments_scope { let _ = std::fs::remove_file(path); }
        if let Some(path) = &self.status_scope { let _ = std::fs::remove_file(path); }
        if let Some(path) = &self.onboarding_scope {
            let _ = std::fs::remove_file(path);
        }
    }
}

impl Cognition for NativeCognition {
    fn requires_thread_isolation(&self) -> bool { self.continuity.is_some() }
    fn worker_status(&self) -> Option<crate::worker_status::WorkerStatusView> {
        self.engine_profile.as_ref().map(|p| crate::app_workers::status(&p.state, Some(&self.session_id)))
    }
    fn prepare_work_turn(&mut self, binding: &crate::entity::ThreadBinding, turn: &str,
        source: crate::ledger::Source, text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        // **SEAM 2 OF THE SPEC'S §5.8a-ii, and it is the one that fires first** — because it
        // is the HOST calling `brief` on the lease's behalf, which no allow-list touches.
        // This function is the only non-test writer of an ECS tool scope, and on its way
        // there it calls `bridge.brief(&scope)` (`:1972` at `5e7a632e`) — the command
        // §5.8a reproduces raising on a work seat. So the rule cannot be kept by
        // restricting the model: the work lease's preparation must not come down this path
        // at all. It has its own, in `bind_work_assignment`, which binds the seat, writes
        // the scope, and stops.
        if let Some(refusal) = work_preparation_refusal(self.role) {
            return Err(CognitionError::Protocol(refusal.into()));
        }
        // Read before the `&self.continuity` borrow, because the assignment scope below
        // needs it and the register lives in the engine state root beside the receipts.
        let profile_state = self.engine_profile.as_ref().map(|p| p.state.clone());
        // **His seat for THIS conversation, resolved before the continuity borrow** — the
        // bind below states what it is and why it is asked rather than assumed.
        let seat = self.ceo_thread_seat(binding.thread_id());
        let Some((bridge, path)) = &self.continuity else { return Ok(()); };
        // **UNCHANGED BEHAVIOR, ON PURPOSE.** `!= Yes` is exactly what `!engine_plugin_loaded`
        // meant while the field was a `bool`: this path runs on the CONVERSATION lease and
        // only after `prepare_request` → `prime_lease_if_needed` has taken a priming turn
        // (`spine.rs:3231`, called at `spine.rs:1963` before the `prepare_work_turn` at
        // `:1974`), so the init frame has landed and `NotYetReported` here would mean the
        // frame never came — which is a fault, not a reason to proceed. The tri-state changes
        // `bind_work_assignment`, which runs BEFORE its lease's first turn; it deliberately
        // changes nothing here.
        if self.engine_profile.is_some() && self.client.reader_state.lock().unwrap().engine_plugin_loaded != InitFact::Yes {
            return Err(CognitionError::Protocol(ENGINE_PLUGIN_ABSENT.into()));
        }
        // **THE READINESS CHECK IS ABOUT WHAT THIS LEASE WAS CONFIGURED WITH, NOT ABOUT A
        // GLOBAL EXPECTATION** — the background-work spec §5.8a-ii's stated consequence of
        // seam 1, which *"must land in the same commit as the omission"*. A work lease is
        // deliberately not given the continuity tools, so a lease-blind assertion here
        // would refuse its turn outright and it would never start.
        //
        // For the conversation lease nothing changes: it is still refused unless the
        // child's own init frame listed both continuity tools (`:1255`).
        if requires_continuity_tools(self.role)
            && self.client.reader_state.lock().map(|s| s.continuity_tools_loaded).ok() != Some(true) {
            return Err(CognitionError::Protocol("The selected engine's continuity tools did not load".into()));
        }
        // **THE SAME RULE, NOW POINTING THE OTHER WAY.** This assertion used to read
        // `engine_profile.is_some()` alone, which was right while `richos_work` was on both
        // leases. It is on the work lease only now (`mcp_config`), so a lease-blind check
        // here would have the front desk refuse every turn of his for not holding a tool it
        // is deliberately no longer given — the exact failure shape the comment above warns
        // about, arrived at from the other side.
        if requires_work_tools(self.role)
            && self.engine_profile.is_some()
            && self.client.reader_state.lock().unwrap().work_tools_loaded != InitFact::Yes {
            return Err(CognitionError::Protocol(WORK_TOOLS_ABSENT.into()));
        }
        // And the front desk's read. Same loudness as the work tools, for the reason
        // `requires_status_tool` states: this is what it answers "what is running" with.
        if requires_status_tool(self.role)
            && self.engine_profile.is_some()
            && !self.client.reader_state.lock().unwrap().status_tool_loaded {
            return Err(CognitionError::Protocol("The desktop status tool did not load".into()));
        }
        if self.engine_profile.is_some() && self.client.reader_state.lock().unwrap().automatic_permissions != InitFact::Yes {
            return Err(CognitionError::Protocol(AUTOMATIC_PERMISSIONS_ABSENT.into()));
        }
        // ===================================================================================
        // HIS OWN CURSOR, ONE PER CONVERSATION THREAD
        // ===================================================================================
        //
        // The seat is `ceo-thread:<thread_id>`, derived here and derived AGAIN in the engine
        // from the row's own thread, so neither side holds a mapping the other can drift
        // from (`ecs::ceo_seat`; `engine/ecs/core/ecs_core.py:181-193`;
        // `engine/ecs/CONTRACT.md:58-60`).
        //
        // **What it buys is the conversation half of his "multiple things in parallel".**
        // Every front desk used to bind the single `ceo-default` row, so thread B's bind
        // upserted thread A's cursor and A's next `checkpoint`, `brief` or `inspect` was
        // refused with *"stale app binding"* — not a race a retry fixes (`ecs_core.py`'s
        // `with_fresh_active_fence`: a `ScopeError` *"is not a race"*), so A's turn
        // dead-lettered. With a row each, two threads bind, checkpoint and read their briefs
        // without touching each other. That was escalation
        // `esc-20260917T192024Z-191918ec`, and the engine side landed at `5cee0cf4`.
        //
        // **The capability is ASKED, never assumed, and the fallback is the old behavior.**
        // An engine without per-thread seats accepts this bind — an unknown JSON field is
        // ignored — and then refuses the first checkpoint, so support cannot be inferred
        // from a bind that worked. `supports_ceo_thread_seats` reads `hello`'s positive
        // answer and its prefix; on `false` the seat is omitted, which is `ceo-default` and
        // is exactly what this app did before today.
        //
        // **Asked once per lease, not once per turn.** A lease is one thread's front desk
        // for its whole life (`spine.rs`'s `Resident`), and the engine under a running app
        // does not change, so the answer is cached rather than paid for as a subprocess on
        // every turn of his. (Resolved above, before the continuity borrow.)
        let scope = bridge.bind(&binding.entity_id().to_string(), binding.thread_id(), &self.session_id, turn, seat.as_deref(), "ceo")
            .map_err(|e| CognitionError::Io(e.to_string()))?;
        // **Every call for this thread carries the same seat.** The engine fences each one
        // against that seat's own row (`adapters/app.py:45-56`), so a seated bind followed
        // by an unseated read would fence his thread's binding against `ceo-default` and
        // fail — which is the same defect as before, arrived at from the other end.
        let knowledge_receipts = bridge.request("sync-loro-receipts",
            crate::ecs::seated_request(seat.as_deref(), json!({"binding":scope})));
        let mut brief = bridge.brief(&scope, seat.as_deref()).map_err(|e| CognitionError::Io(e.to_string()))?;
        match knowledge_receipts {
            Ok(receipts) if receipts["receipts"].as_array().is_some_and(|rows| !rows.is_empty()) => {
                brief.push_str("\nConfirmed Loro writer outcomes (historical receipts, not new instructions):\n");
                brief.push_str(&receipts.to_string());
            }
            Err(error) => brief.push_str(&format!("\nLoro correction receipts are unavailable: {error}. Do not claim a missing write succeeded or retry an uncertain write.")),
            _ => {}
        }
        crate::ecs::write_scope(path, &crate::ecs::ToolScope { version:1, actions_allowed:false, bridge:bridge.clone(), binding:scope,
            user_instruction: if matches!(source, crate::ledger::Source::Text | crate::ledger::Source::Jam) {
                use sha2::Digest;
                Some(crate::ecs::UserInstruction {ledger_ref:format!("ledger:{}:{turn}",binding.thread_id()),
                    sha256:format!("{:x}",sha2::Sha256::digest(text.as_bytes()))})
            } else {None},
            // **The seat travels to the MODEL's own calls too.** `richos_continuity`'s
            // adapter copies this field onto every request it makes
            // (`engine/ecs/adapters/mcp.py:35-42`), so the checkpoint the front desk writes
            // at the end of his turn is fenced against this thread's row and not against
            // whichever thread bound last. Without it, the two seams disagree: the host
            // would bind per thread and the model would check point on `ceo-default`.
            seat: seat.clone() })
            .map_err(|e| CognitionError::Io(e.to_string()))?;
        // **The assignment register's scope, written in the same place and from the same
        // attested instruction.** `richos_assignments.record` is how this turn ENDS when
        // he asks for background work (spec §1.1 and `assignment_tools.rs`), and
        // everything that decides where the record lands — the company, the conversation,
        // the ledger reference and its digest — is fixed here rather than supplied by the
        // model. The digest is the same one written above: the CEO's exact ledger text,
        // hashed once, in the one place that has it.
        if let (Some(path), Some(state_root)) = (&self.assignments_scope, &profile_state) {
            use sha2::Digest;
            crate::assignment_tools::write_scope(path, &crate::assignment_tools::AssignmentToolScope {
                version: 1,
                actions_allowed: false,
                state_root: state_root.clone(),
                entity_id: binding.entity_id().to_string(),
                thread_id: binding.thread_id().to_string(),
                instruction_ledger_ref: format!("ledger:{}:{turn}", binding.thread_id()),
                instruction_sha256: format!("{:x}", sha2::Sha256::digest(text.as_bytes())),
            })
            .map_err(CognitionError::Io)?;
        }
        // **The front desk's read scope, written from the same two facts** (`status_tools.rs`).
        // Company and conversation, and nothing else: there is no grant on this one because
        // it writes nothing, and no instruction because it asks about nothing he said. It is
        // rewritten every turn for the same reason the register's is — the conversation can
        // move between companies, and a scope left pointing at the last one would answer a
        // question about the wrong company's work.
        if let (Some(path), Some(state_root)) = (&self.status_scope, &profile_state) {
            crate::status_tools::write_scope(path, &crate::status_tools::StatusToolScope {
                version: 1,
                state_root: state_root.clone(),
                entity_id: binding.entity_id().to_string(),
                thread_id: binding.thread_id().to_string(),
            })
            .map_err(CognitionError::Io)?;
        }
        let reason = self.client.prompt_context_only(&crate::reprime::context_only_priming(&brief), on_item)?;
        if reason != "end_turn" { return Err(CognitionError::PrimingStopped(reason)); }
        Ok(())
    }

    /// The work lease's preparation — **the sibling path of `prepare_work_turn`, and its
    /// whole point is what it does not do.**
    ///
    /// It binds the assignment's own seat, writes the scope, opens the standing grant, and
    /// stops. No `brief`, no `sync-loro-receipts`, no priming prompt: those write and read
    /// the CEO's executive continuity, the work lease has no business in it, and
    /// `audience: "worker"` (§5.8c) exists precisely to keep this lease out of it.
    ///
    /// **The readiness checks it DOES keep** are the ones about what this lease was given:
    /// the engine plugin, the work tools, and automatic permission checks. The continuity
    /// tools are deliberately absent, so they are deliberately not asserted.
    fn bind_work_assignment(&mut self, work: &crate::cognition::WorkAssignment) -> Result<(), CognitionError> {
        if let Some(refusal) = assignment_binding_refusal(self.role) {
            return Err(CognitionError::Protocol(refusal.into()));
        }
        let Some((bridge, path)) = &self.continuity else {
            return Err(CognitionError::Protocol("This work connection has no continuity scope.".into()));
        };
        // =================================================================================
        // THE READINESS GATE ASKS ABOUT A REPORTED FACT, NEVER AN UNREPORTED ONE
        // =================================================================================
        //
        // **This gate refused every background job the product ever had, and it did so on
        // leases whose plugin had loaded.** Measured on candidate .7
        // (`v1.2.0-nightly.20260918.1`, source `9da3c7d5`) on 2026-09-18: two assignments,
        // `581ed860` and `1eb68094`, both `"state":"failed"` with
        // `"detail":"cognition protocol: The desktop engine plugin did not load"`, both
        // `"work_session":null`, at 1789719190997−1789719184452 = **6545 ms** and
        // 1789719375941−1789719368455 = **7486 ms** after registration — the time it takes
        // to spawn `claude` and answer the handshake, and nothing like the time it takes to
        // run a turn.
        //
        // The cause is an ordering fact, not a configuration one. `work_host.rs`'s `run_one`
        // calls `ensure_lease` (`start_work_lease` → `spawn_with_tools`, handshake only) and
        // then this function, BEFORE the assignment's turn. The facts below are read from
        // `system/init`, and `child_args`'s own doc says that frame *"arrives with the first
        // TURN"* — the `initialize` control handshake reads a `subtype` and keeps nothing
        // else. So at this line the child has reported nothing, and the `bool` these three
        // facts used to be said `false`, and `false` was read as "we were told no".
        //
        // **The plugin had in fact loaded.** The same run left
        // `engine-state/evidence/060e1ec9…/callbacks.jsonl` holding a `SessionStart` callback
        // with `"source":"startup"` — a hook registered ONLY by this plugin
        // (`engine_profile.rs`'s `hooks/hooks.json`). The app refused the job for the absence
        // of a plugin while holding, on its own disk, the plugin's own evidence that it was
        // there.
        //
        // **So only a REPORTED absence refuses here, and the loudness moves rather than
        // softens.** `--plugin-dir` accepts an unusable path and reports success (cell K4),
        // and this check is still the only thing that catches that — it is now asked at
        // `Cognition::work_readiness_after_turn`, on this same lease, against these same
        // three facts, with these same three sentences, once its first turn has brought the
        // frame that can answer them. A plugin that really did not load still fails the job
        // and still says exactly this.
        //
        // **Why not read the `SessionStart` evidence here instead**, given it exists and
        // proves the positive? Measured and rejected: that directory's birth time was
        // 1789719190 and the refusal was raised at 1789719190997 — the hook's evidence and
        // the refusal landed in the same second. Gating on it would mean waiting on an
        // asynchronous Python hook with a deadline, which is a timing guess dressed as a
        // check, and a slow hook would resurrect this exact false refusal.
        if self.engine_profile.is_some() {
            let facts = work_readiness_facts(&self.client.reader_state.lock().unwrap());
            if let Some(sentence) = work_binding_readiness_refusal(facts) {
                return Err(CognitionError::Protocol(sentence.into()));
            }
        }
        let binding = bridge
            .bind_work_seat(&work.entity_id, &work.thread_id, &self.session_id, &work.obligation_id, &work.seat)
            .map_err(|e| CognitionError::Io(e.to_string()))?;
        let binding_for_reads = binding.clone();
        // **The standing action grant (§5.4), and the frozen instruction (§3.6).**
        // `actions_allowed: true` with no visible turn is the whole of what lets a
        // background lease reach the work tools at all (`mega-lander/app.py:41-42`); the
        // instruction reference is the one from the turn in which he gave the assignment,
        // so the engine's completion gate checks a durable instruction rather than a live
        // one, and its meaning — his, visible, host-attested — is unchanged.
        crate::ecs::write_scope(path, &crate::ecs::ToolScope {
            version: 1,
            actions_allowed: true,
            bridge: bridge.clone(),
            binding,
            user_instruction: Some(crate::ecs::UserInstruction {
                ledger_ref: work.instruction_ledger_ref.clone(),
                sha256: work.instruction_sha256.clone(),
            }),
            seat: Some(work.seat.clone()),
        })
        .map_err(|e| CognitionError::Io(e.to_string()))?;
        self.work_binding = Some((binding_for_reads, work.seat.clone()));
        Ok(())
    }

    /// The moved half of the binding gate — see [`work_turn_readiness_refusal`] and
    /// [`Cognition::work_readiness_after_turn`].
    ///
    /// A lease with no engine profile was never subject to these three assertions in the
    /// first place (every one of them is guarded by `engine_profile.is_some()`), so it
    /// answers `Ok(())` rather than inventing a requirement it was never given.
    fn work_readiness_after_turn(&self) -> Result<(), CognitionError> {
        if self.engine_profile.is_none() {
            return Ok(());
        }
        let facts = work_readiness_facts(&self.client.reader_state.lock().unwrap());
        match work_turn_readiness_refusal(facts) {
            Some(sentence) => Err(CognitionError::Protocol(sentence.into())),
            None => Ok(()),
        }
    }

    /// The obligation behind the assignment this lease is carrying — read on ITS seat.
    ///
    /// This is what settles an assignment, and nothing else does. The engine says why in
    /// its own words: *"An assignment whose workers have all stopped is NOT settled: that
    /// is exactly the state where it has run, stopped at integrate and is waiting for
    /// him"* (`richos/engine/mega-lander/app.py:664-669`).
    fn obligation_state(&self, obligation: &str) -> Result<crate::cognition::ObligationState, CognitionError> {
        let (Some((bridge, _)), Some((binding, seat))) = (&self.continuity, &self.work_binding) else {
            return Err(CognitionError::Protocol("This connection is not carrying an assignment.".into()));
        };
        bridge.obligation_state(binding, Some(seat), obligation)
            .map_err(|e| CognitionError::Io(e.to_string()))
    }

    /// Revoke the standing grant — spec §5.4, per assignment, by name.
    ///
    /// **A grant that cannot be revoked forces the lease down** rather than being left
    /// open, which is the rule the conversation lease already follows at turn end
    /// (`:2041-2055`). A background lease holding an un-revokable standing grant with no
    /// visible turn is strictly worse than that case, so it gets the same answer.
    fn revoke_work_assignment(&mut self) -> Result<(), CognitionError> {
        let Some((_, path)) = &self.continuity else { return Ok(()) };
        if !path.exists() { return Ok(()); }
        if let Err(error) = crate::ecs::set_actions_allowed(path, false) {
            let _ = self.client.child.kill();
            let _ = self.client.child.wait();
            let _ = std::fs::remove_file(path);
            return Err(CognitionError::Io(error.to_string()));
        }
        Ok(())
    }

    fn set_onboarding_scope(&mut self, entity: &crate::entity::EntityId,
        central_root: &Path, record_path: &Path) -> Result<(), CognitionError> {
        if let Some(path) = &self.onboarding_scope {
            crate::onboarding_tools::write_scope(path, &crate::onboarding_tools::OnboardingToolScope {
                version: 1, entity_id: entity.to_string(), actions_allowed: false,
                central_root: central_root.to_path_buf(), record_path: record_path.to_path_buf(),
            }).map_err(|e| CognitionError::Io(e.to_string()))?;
        }
        Ok(())
    }


    fn session_id(&self) -> &str {
        &self.session_id
    }

    fn reprime(&mut self, priming_text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<(), CognitionError> {
        // The priming turn runs a REAL turn. Its TEXT is still discarded (never rendered);
        // its MACHINERY flows to the caller, which stamps it `internal: true` /
        // `turn_id: None` per §1.5 — retained for debugging, never in a thread render,
        // honouring the standing order that Rich never reveals session rotation.
        let reason = self.client.prompt_context_only(&crate::reprime::context_only_priming(priming_text), on_item)?;
        if reason != "end_turn" {
            return Err(CognitionError::PrimingStopped(reason));
        }
        if self.onboarding_scope.is_some() {
            self.client.ensure_onboarding_tools_loaded()?;
        }
        Ok(())
    }

    fn prompt(&mut self, text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        {
            let operation = self.client.operation_cancel.lock().unwrap();
            if operation.active && operation.requested {
                return Ok(STOP_REASON_CANCELLED.to_string());
            }
            for (index, grant) in self.client.action_grants.iter().enumerate() {
                if let Err(error) = grant.set(true) {
                    for previous in &self.client.action_grants[..index] {
                        if previous.set(false).is_err() { let _ = std::fs::remove_file(previous.path()); }
                    }
                    return Err(CognitionError::Io(error));
                }
            }
        }
        let result = self.client.prompt(text, on_item).map_err(CognitionError::from);
        let _operation = self.client.operation_cancel.lock().unwrap();
        if let Some((_, path)) = &self.continuity {
            if let Err(error) = crate::ecs::set_actions_allowed(path, false) {
                let _ = self.client.child.kill(); let _ = self.client.child.wait();
                let _ = std::fs::remove_file(path);
                if let Some(onboarding) = &self.onboarding_scope { let _ = std::fs::remove_file(onboarding); }
                return Err(CognitionError::Io(error.to_string()));
            }
        }
        if let Some(path) = &self.onboarding_scope {
            if let Err(error) = crate::onboarding_tools::set_actions_allowed(path, false) {
                // A lease whose grant cannot be revoked must not accept another operation.
                let _ = self.client.child.kill();
                let _ = self.client.child.wait();
                let _ = std::fs::remove_file(path);
                return Err(CognitionError::Io(error));
            }
        }
        if let Some(profile) = &self.engine_profile {
            let workers = crate::app_workers::status(&profile.state, Some(&self.session_id));
            if !workers.is_attributed() || workers.active > 0 || workers.liveness_unknown > 0 {
                let _ = self.client.child.kill(); let _ = self.client.child.wait();
                return Err(CognitionError::Protocol("Worker settlement could not be verified at turn end. Owned processes were stopped; their workspaces and receipts were retained for reconciliation.".into()));
            }
        }
        result
    }

    fn prompt_context_only(&mut self, text: &str, on_item: &mut dyn FnMut(TurnItem)) -> Result<String, CognitionError> {
        Ok(self.client.prompt_context_only(text, on_item)?)
    }

    fn cancel_handle(&self) -> Option<Arc<dyn TurnCancel>> {
        Some(self.client.cancel_handle())
    }

    fn drain_between_turn(&mut self) -> Vec<MachineryRecord> {
        self.client.drain_between_turn(&self.session_id)
    }
}

#[cfg(test)]
mod native_driver_tests {
    use super::*;

    // ---- the background-work spec's §5.8a-ii seams ------------------------------------

    fn fixture_bridge(root: &Path) -> crate::ecs::EcsBridge {
        crate::ecs::EcsBridge {
            python: root.join("runtime/bin/python3"),
            component: root.join("engine/ecs"),
            state_root: root.join("ecs"),
        }
    }

    fn fixture_profile(root: &Path) -> crate::engine_profile::EngineProfile {
        crate::engine_profile::EngineProfile {
            engine: root.join("engine"),
            coordination: root.join("coordination"),
            plugin: root.join("plugin"),
            state: root.join("engine-state"),
            runtime: crate::runtime::EngineRuntime {
                root: root.join("runtime"),
                python: root.join("runtime/bin/python3"),
                node: root.join("runtime/bin/node"),
                git: root.join("runtime/bin/git"),
                versions: Default::default(),
            },
            work_scope: None,
            permissions: std::sync::Arc::new(crate::permissions::PermissionDesk::default()),
        }
    }

    /// **SEAM 1.** The work lease's MCP config does not register `richos_continuity`, and
    /// the conversation lease's does.
    ///
    /// The negative is the load-bearing half, so it has a positive control in the same
    /// test: the identical call with `LeaseRole::Conversation` DOES register the server,
    /// which is what makes its absence evidence rather than a config that never had it.
    ///
    /// **Why the omission and not an allow-list entry** (spec §5.8a-ii): `permissions.rs`
    /// auto-allows `mcp__richos_continuity__checkpoint` and `…__inspect` on a
    /// process-global tool-name match, and those are exactly the two tools that server
    /// exposes — so the desk cannot tell the two leases apart and the work lease would have
    /// had un-prompted checkpoint access. That coupling is asserted here too, against the
    /// live `permissions.rs` decision, so a later edit that removed the auto-allow would
    /// tell whoever is reading this why this test exists.
    #[test]
    fn a_work_leases_config_omits_the_continuity_server_and_keeps_the_work_server() {
        let root = std::env::temp_dir().join(format!("mcp-config-{}", uuid::Uuid::new_v4()));
        let bridge = fixture_bridge(&root);
        let profile = fixture_profile(&root);
        let scope = root.join("scope.json");
        let continuity = root.join("continuity.json");
        let executable = root.join("RichOS");

        let assignments = root.join("assignments.json");
        let status = root.join("status.json");

        let work = mcp_config(&executable, &scope, &assignments, &status, Some((&bridge, &continuity)), Some(&profile), LeaseRole::Work);
        let servers = &work["mcpServers"];
        assert!(servers.get("richos_continuity").is_none(), "the work lease was given the continuity server");
        assert!(servers.get("richos_work").is_some(), "the work lease was not given the work server");
        // **This assertion was `is_some()` until 2026-09-18 and it was asserting the defect.**
        // Ray's candidate-.8 row 1: the work lease's onboarding scope is written by nothing,
        // so the server named a file that never existed and the grant over it failed the job
        // 6.317 s in. See `a_work_lease_never_holds_a_grant_over_a_company_scope_nothing_writes`.
        assert!(servers.get("richos_onboarding").is_none(),
            "the work lease was given the company-notes server over a scope only spine.rs writes");
        // And it cannot register more assignments for itself (`assignment_tools.rs`).
        assert!(servers.get(crate::assignment_tools::SERVER_NAME).is_none(),
            "the work lease was given the assignment register");
        // Nor read the front desk's record (`status_tools.rs`).
        assert!(servers.get(crate::status_tools::SERVER_NAME).is_none(),
            "the work lease was given the front desk's status server");

        // Positive control: the same call for the conversation DOES register its two.
        let chat = mcp_config(&executable, &scope, &assignments, &status, Some((&bridge, &continuity)), Some(&profile), LeaseRole::Conversation);
        assert!(chat["mcpServers"].get("richos_continuity").is_some(), "the conversation lost its continuity server");
        assert!(chat["mcpServers"].get(crate::assignment_tools::SERVER_NAME).is_some(),
            "the conversation has no way to end a turn on a receipt");
        assert!(chat["mcpServers"].get(crate::status_tools::SERVER_NAME).is_some(),
            "the front desk has no way to look at what is running");

        // And the reason the omission is the enforcement rather than the desk: the desk
        // auto-allows both of that server's tools, with nothing per-lease to discriminate on.
        let grant = root.join("grant.json");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(&grant, json!({"version":1,"actions_allowed":true,"binding":{"entity_id":"depot",
            "thread_id":"thread","session_id":"session","turn_id":"turn","audience":"ceo","revision":1}}).to_string()).unwrap();
        let desk = crate::permissions::ScopedPermissions {
            desk: std::sync::Arc::new(crate::permissions::PermissionDesk::default()),
            scope: grant,
        };
        for tool in ["mcp__richos_continuity__checkpoint", "mcp__richos_continuity__inspect"] {
            assert!(
                matches!(desk.decide(&json!({"tool_name": tool, "input": {}})), PermissionDecision::Allow { .. }),
                "{tool} is no longer auto-allowed; seam 1's reasoning needs re-reading"
            );
        }
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// **THE FRONT DESK'S WHOLE TOOL INVENTORY, AND THE BACK END'S**, asserted as two
    /// complete lists rather than as four separate absences.
    ///
    /// The CEO's Two Riches page: *"the job of the front desk Rich is solely talking to the
    /// CEO and relaying info to and from the back-end Rich"*, and note 3 *"The front desk
    /// gets no orchestration tools, so it cannot drift into doing the work."* This is that
    /// sentence as a measurement. It is written as an exact set on purpose: a test that
    /// asserted only `richos_work`'s absence would go on passing if a fifth server appeared
    /// beside it, and "no orchestration tools" is a claim about everything on the lease.
    #[test]
    fn the_front_desk_holds_the_register_and_the_read_and_nothing_that_does_the_work() {
        let root = std::env::temp_dir().join(format!("mcp-inventory-{}", uuid::Uuid::new_v4()));
        let bridge = fixture_bridge(&root);
        let profile = fixture_profile(&root);
        let (scope, continuity, executable) =
            (root.join("scope.json"), root.join("continuity.json"), root.join("RichOS"));
        let (assignments, status) = (root.join("assignments.json"), root.join("status.json"));

        let names = |config: &Value| {
            let mut found: Vec<String> =
                config["mcpServers"].as_object().unwrap().keys().cloned().collect();
            found.sort();
            found
        };

        let chat = mcp_config(&executable, &scope, &assignments, &status,
            Some((&bridge, &continuity)), Some(&profile), LeaseRole::Conversation);
        assert_eq!(
            names(&chat),
            vec!["richos_assignments", "richos_continuity", "richos_onboarding", "richos_status"],
            "the front desk's tool list moved"
        );
        // Named on its own as well, because the list above is the WHAT and this is the WHY.
        assert!(chat["mcpServers"].get("richos_work").is_none(),
            "the front desk can still do the work; note 3 is not built");

        // The back end is the other half of the same sentence: it holds the work, and it can
        // neither give itself more of it nor read the front desk's record.
        let work = mcp_config(&executable, &scope, &assignments, &status,
            Some((&bridge, &continuity)), Some(&profile), LeaseRole::Work);
        assert_eq!(
            names(&work),
            vec!["richos_work"],
            "the back end's tool list moved"
        );
        // **The back end holds the work and NOTHING ELSE, and that is the third absence.**
        // The list above read `["richos_onboarding", "richos_work"]` until 2026-09-18. Named
        // on its own for the same reason `richos_work`'s absence is named above the
        // conversation list: the set is the WHAT and this is the WHY. Saving his answers about
        // his own company is something he says in a visible turn; a back end holding those
        // two tools under §5.4's standing grant could rewrite them with no turn at all.
        assert!(work["mcpServers"].get("richos_onboarding").is_none(),
            "the back end can still rewrite the CEO's company notes");
        // Nothing here wrote to the root — `mcp_config` builds a value and touches no disk,
        // which is the property that lets this assert the inventory without a child process.
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A lease built through the REAL [`NativeClient::spawn_with_tools`], so the grant list
    /// under test is the production one rather than a hand-assembled `Vec`.
    ///
    /// **No engine profile, deliberately.** The readiness gates and the worker-settlement read
    /// are about a delivered engine and are covered by `hand_built_work_lease`; this is about
    /// the grants, and a profile here would demand a real Python supervisor. Everything the
    /// grant loop reads is present: the four app-owned paths, the continuity scope, the role.
    ///
    /// The onboarding path is **never written**, which is exactly the state `start_work_lease`
    /// leaves it in on every machine.
    fn lease_with_production_grants(tag: &str, role: LeaseRole, script_body: &str)
        -> (NativeCognition, std::path::PathBuf) {
        let root = std::env::temp_dir().join(format!("richos-grant-{tag}-{}", uuid::Uuid::new_v4().simple()));
        let scopes = root.join("scopes");
        std::fs::create_dir_all(&scopes).unwrap();
        let identity = uuid::Uuid::new_v4();
        let onboarding = scopes.join(format!("{identity}-onboarding.json"));
        let assignments = scopes.join(format!("{identity}-assignments.json"));
        let status = scopes.join(format!("{identity}-status.json"));
        let continuity = scopes.join(format!("{identity}-work.json"));
        let bridge = fixture_bridge(&root);
        // **The one grant on a work lease that DOES have a file under it**, written here
        // because `start_work_lease` writes it (`{"version":1,"actions_allowed":false}`).
        // Written in full rather than as that two-field stub because `ecs::ToolScope` requires
        // `bridge` and `binding` and denies unknown fields, so the stub is only readable after
        // `bind_work_assignment` has replaced it — which in production it always has, since
        // `work_host.rs`'s `run_one` binds before it prompts.
        crate::ecs::write_scope(&continuity, &crate::ecs::ToolScope {
            version: 1,
            actions_allowed: false,
            bridge: bridge.clone(),
            binding: crate::ecs::Binding {
                entity_id: "qa-test-co".into(),
                thread_id: "thr_one".into(),
                session_id: "sess_one".into(),
                turn_id: "ob-1".into(),
                audience: "worker".into(),
                revision: 1,
            },
            user_instruction: None,
            seat: Some("work-seat:ob-1".into()),
        })
        .unwrap();
        let (doctrine, skills) = (doctrine_fixture(), skills_fixture());
        let script = write_script(&format!("grant-{tag}"), script_body);
        let client = NativeClient::spawn_with_tools(
            &script,
            Path::new("/tmp"),
            Some((&doctrine, &skills)),
            Some((&root.join("RichOS"), &onboarding, &assignments, &status)),
            Some((&bridge, &continuity)),
            None,
            None,
            role,
        )
        .expect("the handshake should succeed");
        let session_id = client.session_id().to_string();
        // Mirrors its constructor exactly: `start_with_engine` holds the path, and since
        // 2026-09-18 `start_work_lease` holds `None`.
        let onboarding_scope = match role {
            LeaseRole::Conversation => Some(onboarding),
            LeaseRole::Work => None,
        };
        let lease = NativeCognition {
            client,
            session_id,
            onboarding_scope,
            assignments_scope: None,
            status_scope: None,
            continuity: Some((bridge, continuity)),
            work_binding: None,
            engine_profile: None,
            role,
            ceo_thread_seats: None,
        };
        (lease, root)
    }

    fn grant_names(client: &NativeClient) -> Vec<&'static str> {
        client
            .action_grants
            .iter()
            .map(|grant| match grant {
                ActionGrant::Onboarding(_) => "onboarding",
                ActionGrant::Assignments(_) => "assignments",
                ActionGrant::Continuity(_) => "continuity",
            })
            .collect()
    }

    /// **RAY'S CANDIDATE-.8 ROW 1, AS A TEST — the third way a background job died in one
    /// morning, and the only one of the three that was never about the engine.**
    ///
    /// Measured on his walk (`docs/verification/2026-09-18-nightly-1.2.0-20260918.2-onscreen-audit.md`
    /// §1 row 1, try 3, on the instance whose engine had just been replaced so the readiness
    /// gate passed): the job failed **6.317 s** after registration — re-derived from his own
    /// two timestamps, `10:45:54.192Z − 10:45:47.875Z` — with *"cognition io: Choose a company
    /// before saving interview answers."*, for a company that WAS selected and an interview
    /// nobody had started. `notes.txt` never changed.
    ///
    /// **The chain, re-derived at this commit, every link cited:**
    ///
    /// 1. `start_work_lease` computes `scopes/{identity}-onboarding.json`. Nothing writes it
    ///    and nothing can: `Cognition::set_onboarding_scope` is called from exactly two places,
    ///    `spine.rs:3093` and `spine.rs:3278`, and both are the conversation's lease.
    /// 2. `spawn_with_tools` put `ActionGrant::Onboarding` on the grant list for EVERY role —
    ///    only `ActionGrant::Assignments` carried the `LeaseRole::Conversation` filter.
    /// 3. `work_host.rs`'s `run_one` calls `lease.prompt(…)`, and `prompt`'s first act is to
    ///    open every grant in that list, all-or-nothing.
    /// 4. `ActionGrant::Onboarding::set(true)` → `onboarding_tools::set_actions_allowed` →
    ///    `read_scope` → `File::open` on a path that is not there → the sentence at
    ///    `onboarding_tools.rs:137`, returned as `CognitionError::Io`, which `cognition.rs:21`
    ///    renders with the `cognition io:` prefix he read on the card.
    ///
    /// So it fired **before the turn was ever sent** — which is why 6.317 s is a spawn and a
    /// handshake and nothing like a run, why no model token was spent, and why the assignment's
    /// record never left `Preparing`.
    ///
    /// **Four arms, and the two positive controls are the point.** The sentence must still be
    /// raised by a grant over a missing scope (A) and must still fail a CONVERSATION lease with
    /// no company bound (D). Without those, the two negatives would be a check that moved
    /// rather than a defect that went away.
    #[test]
    fn a_work_lease_never_holds_a_grant_over_a_company_scope_nothing_writes() {
        const INTERVIEW: &str = "Choose a company before saving interview answers.";

        // ---- A. POSITIVE CONTROL: the sentence is still live, and still says this ----------
        // Unchanged, and it must stay unchanged: `read_scope` mapping a missing file to this
        // sentence is correct for the seat that asks the question.
        let absent = std::env::temp_dir()
            .join(format!("richos-no-scope-{}", uuid::Uuid::new_v4().simple()))
            .join("never-written.json");
        assert_eq!(
            ActionGrant::Onboarding(absent.clone()).set(true),
            Err(INTERVIEW.to_string()),
            "the sentence this test is about is no longer raised, so its negatives prove nothing"
        );
        // And deliberately NOT given the `!path.exists() => Ok(())` guard `Assignments` has:
        // on a conversation lease a missing scope means no company is bound, and failing there
        // is what stops a model writing company notes with no company chosen.
        assert_eq!(
            ActionGrant::Assignments(absent).set(true),
            Ok(()),
            "the two app-owned grants no longer differ, which is the distinction arm D rests on"
        );

        // ---- B. THE FIX, STRUCTURALLY: the grant list, from the real constructor ----------
        let (work, work_root) =
            lease_with_production_grants("work-list", LeaseRole::Work, SILENT_AFTER_HANDSHAKE);
        assert_eq!(
            grant_names(&work.client),
            vec!["continuity"],
            "a work lease's grant list is not just its own continuity scope"
        );
        assert!(
            work.onboarding_scope.is_none(),
            "a work lease is carrying a company scope nothing writes"
        );
        drop(work);
        let _ = std::fs::remove_dir_all(&work_root);

        let (chat, chat_root) =
            lease_with_production_grants("chat-list", LeaseRole::Conversation, SILENT_AFTER_HANDSHAKE);
        assert_eq!(
            grant_names(&chat.client),
            vec!["onboarding", "assignments", "continuity"],
            "the front desk lost a grant it needs — the fix has moved, not landed"
        );
        drop(chat);
        let _ = std::fs::remove_dir_all(&chat_root);

        // ---- C. THE FIX, BEHAVIORALLY: the same call that failed his job now takes a turn --
        let frame = work_init_frame(true, true, true);
        let (mut lease, root) =
            lease_with_production_grants("work-turn", LeaseRole::Work, &one_turn_reporting(&frame));
        let mut items = 0usize;
        let stop = crate::cognition::Cognition::prompt(&mut lease, "do the job", &mut |_| items += 1)
            .expect("a work lease's first turn must not be refused over a company scope");
        assert_eq!(stop, "end_turn");
        assert!(items > 0, "the child's stream never reached the caller, so nothing was proved");
        drop(lease);
        let _ = std::fs::remove_dir_all(&root);

        // ---- D. POSITIVE CONTROL: the front desk with no company bound still refuses -------
        // `spine.rs`'s `None => Ok(())` means an unbound conversation writes no scope either,
        // and that lease must still hit exactly the sentence — the fix is a role gate, not a
        // relaxation of the check.
        let (mut chat, chat_root) = lease_with_production_grants(
            "chat-unbound",
            LeaseRole::Conversation,
            &one_turn_reporting(&frame),
        );
        let refusal = crate::cognition::Cognition::prompt(&mut chat, "hello", &mut |_| {})
            .expect_err("a conversation with no company bound must still refuse")
            .to_string();
        assert!(
            refusal.contains(INTERVIEW),
            "the front desk's own check was relaxed along with the work lease's: {refusal}"
        );
        drop(chat);
        let _ = std::fs::remove_dir_all(&chat_root);
    }

    /// **THE SEAT SPELLING, AND THAT NOTHING INVENTS IT** — the app derives his per-thread
    /// cursor and the engine derives the same string from the row's own thread, so this is
    /// the app's half of a name that is stored nowhere.
    ///
    /// The engine's own derivation is `CEO_SEAT_PREFIX + thread_id`
    /// (`engine/ecs/core/ecs_core.py:181-193`), and its `is_ceo_row` re-derives it from the
    /// row and requires the `ceo` audience (`:196-213`) — so a seat spelled differently
    /// here would not be refused at the bind, it would be accepted and then fail at the
    /// first checkpoint as though it belonged to somebody else.
    #[test]
    fn his_seat_is_derived_from_the_thread_and_never_from_a_stored_mapping() {
        assert_eq!(crate::ecs::CEO_SEAT_PREFIX, "ceo-thread:");
        assert_eq!(crate::ecs::ceo_seat("thread-one").as_deref(), Some("ceo-thread:thread-one"));
        // The legacy single cursor still exists and is still his — an engine without
        // per-thread seats, or a thread id the engine could not accept, binds it.
        assert_eq!(crate::entity::PERSON_DEFAULT, "ceo-default");
        assert_eq!(crate::ecs::ceo_seat(""), None);
        assert_eq!(crate::ecs::ceo_seat("   "), None);
        assert_eq!(crate::ecs::ceo_seat(&"t".repeat(1100)), None);
    }

    /// **SEAM 2**, the one that fires first, because it is the HOST calling `brief` rather
    /// than the model asking for it: `prepare_work_turn` is the only non-test writer of an
    /// ECS tool scope and calls `bridge.brief(&scope)` on its way there, which spec §5.8a
    /// reproduces raising on a work seat. A work lease must not come down that path at all.
    ///
    /// Asserted without a child process by driving the role gate directly. The positive
    /// control is the other arm: `bind_work_assignment` is refused on a conversation lease,
    /// so neither role can quietly take the other's path.
    #[test]
    fn neither_lease_can_take_the_others_preparation_path() {
        // The refusals are decided before anything else in either function, so a lease
        // value with no live child is enough to exercise exactly the gate under test.
        assert_eq!(
            work_preparation_refusal(LeaseRole::Work),
            Some("A background work connection does not take conversation turns.")
        );
        assert_eq!(work_preparation_refusal(LeaseRole::Conversation), None);
        assert_eq!(
            assignment_binding_refusal(LeaseRole::Conversation),
            Some("The conversation's connection does not take background assignments.")
        );
        assert_eq!(assignment_binding_refusal(LeaseRole::Work), None);
    }

    /// The readiness assertion is per-lease (spec §5.8a-ii's stated consequence): a work
    /// lease was deliberately not given the continuity tools, so requiring them would have
    /// refused its turn outright and it would never have started. The conversation lease
    /// still requires them.
    #[test]
    fn the_continuity_tools_readiness_check_is_about_what_this_lease_was_given() {
        assert!(requires_continuity_tools(LeaseRole::Conversation));
        assert!(!requires_continuity_tools(LeaseRole::Work));
    }

    /// A work lease assembled by hand, so the binding gate can be driven without the real
    /// engine delivery `start_work_lease` needs (a Python supervisor, a rendered profile).
    /// Everything the gate reads is here: the role, the continuity scope, the engine
    /// profile, and a client whose reader state is whatever its scripted child has said.
    fn hand_built_work_lease(tag: &str, script_body: &str) -> (NativeCognition, std::path::PathBuf) {
        let root = std::env::temp_dir().join(format!("work-bind-{tag}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let script = write_script(&format!("work-bind-{tag}"), script_body);
        let client = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture())
            .expect("the handshake should succeed");
        let session_id = client.session_id().to_string();
        let lease = NativeCognition {
            client,
            session_id,
            onboarding_scope: None,
            assignments_scope: None,
            status_scope: None,
            continuity: Some((fixture_bridge(&root), root.join("work-scope.json"))),
            work_binding: None,
            engine_profile: Some(fixture_profile(&root)),
            role: LeaseRole::Work,
            ceo_thread_seats: None,
        };
        (lease, root)
    }

    fn fixture_assignment() -> crate::cognition::WorkAssignment {
        crate::cognition::WorkAssignment {
            entity_id: "qa-co".into(),
            thread_id: "thr_one".into(),
            assignment_id: "assign-1".into(),
            obligation_id: "ob-1".into(),
            seat: "work-seat:ob-1".into(),
            instruction_ledger_ref: "ledger:thr_one:turn_one".into(),
            instruction_sha256: "0".repeat(64),
        }
    }

    /// A child that answers the handshake and then says nothing. A lease that has run no
    /// turn, which is every work lease at the moment its assignment is bound.
    const SILENT_AFTER_HANDSHAKE: &str = "read -r line\n\
         printf '%s\\n' '{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"req_init\",\"response\":{}}}'\n\
         sleep 5\n";

    /// **THE DEFECT CANDIDATE .7 FOUND, AS A TEST — and it is a false NEGATIVE, not a
    /// conservative reading.**
    ///
    /// `bind_work_assignment` runs before the work lease's first turn (`work_host.rs`'s
    /// `run_one`: `ensure_lease`, then bind, then the turn), and `child_args`'s own doc says
    /// the init frame *"arrives with the first TURN"*. So at the bind the child has reported
    /// nothing, and a gate that read `false` for "nobody has told us" refused **every**
    /// background job on every machine: two assignments failed this way on 2026-09-18 at
    /// 6.545 s and 7.486 s after registration, `work_session: null` on both.
    ///
    /// The lease is refused here for the reason it SHOULD be — the fixture bridge cannot
    /// hold a work seat — and that positive assertion is what makes the three negatives
    /// evidence rather than a gate that moved somewhere else.
    #[test]
    fn a_fresh_work_lease_is_never_refused_over_a_fact_its_child_has_not_reported_yet() {
        let (mut lease, root) = hand_built_work_lease("fresh", SILENT_AFTER_HANDSHAKE);
        let refusal = lease
            .bind_work_assignment(&fixture_assignment())
            .expect_err("the fixture bridge cannot hold a seat, so this must still refuse")
            .to_string();
        for unreported in [
            "The desktop engine plugin did not load",
            "The desktop work tools did not load",
            "did not enable automatic permission checks",
        ] {
            assert!(
                !refusal.contains(unreported),
                "a lease that has run no turn was refused over a fact nobody has reported: {refusal}"
            );
        }
        assert!(
            refusal.contains("overwrite the CEO's own"),
            "the binding must reach the seat bind, or the negatives above prove nothing: {refusal}"
        );
        // And the unreported facts are still unreported — the gate passed because it asked
        // about a reported absence, not because the fields were quietly made optimistic.
        let state = lease.client.reader_state.lock().unwrap();
        for fact in [state.engine_plugin_loaded, state.work_tools_loaded, state.automatic_permissions] {
            assert_eq!(fact, InitFact::NotYetReported);
        }
        drop(state);
        drop(lease);
        let _ = std::fs::remove_dir_all(&root);
    }

    /// A child that answers the handshake, then answers ONE turn with `init` and a result.
    fn one_turn_reporting(init: &serde_json::Value) -> String {
        format!(
            "read -r line\n\
             printf '%s\\n' '{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"success\",\"request_id\":\"req_init\",\"response\":{{}}}}}}'\n\
             read -r line\n\
             printf '%s\\n' '{init}'\n\
             printf '%s\\n' '{{\"type\":\"result\",\"subtype\":\"success\",\"stop_reason\":\"end_turn\"}}'\n\
             while read -r line; do :; done\n"
        )
    }

    fn work_init_frame(plugin: bool, work_tools: bool, auto: bool) -> serde_json::Value {
        let mut plugins = vec![json!({"name":"rich-skills","version":"1.0.0"})];
        if plugin {
            plugins.push(json!({"name": crate::engine_profile::PLUGIN_NAME, "version":"1.2.0"}));
        }
        let tools: Vec<&str> = if work_tools {
            vec!["mcp__richos_work__repositories", "mcp__richos_work__prepare",
                 "mcp__richos_work__inspect", "mcp__richos_work__integrate", "mcp__richos_work__complete"]
        } else {
            // Four of the five. A partial inventory must read as absent, not as present.
            vec!["mcp__richos_work__repositories", "mcp__richos_work__prepare",
                 "mcp__richos_work__inspect", "mcp__richos_work__integrate"]
        };
        json!({"type":"system","subtype":"init","plugins":plugins,"tools":tools,
               "permissionMode": if auto { "auto" } else { "default" }})
    }

    /// **THE POSITIVE CONTROL, AND IT IS THE HALF THAT MAKES THE FIX A MOVE RATHER THAN A
    /// RELAXATION.** A lease whose own init frame does not list the engine plugin still fails
    /// its assignment, with the identical sentence, in both of the places that can now say so:
    /// after its first turn (`work_readiness_after_turn`, which `work_host.rs`'s `run_one`
    /// reads at step 3a) and at the NEXT binding on the same lease, where the absence is by
    /// then a reported fact.
    ///
    /// Cell K4 is why this cannot be allowed to go quiet: `--plugin-dir` naming a path it
    /// cannot use exits 0 with a clean handshake and `plugins: []`, so this assertion is the
    /// only thing between that and a background job that silently runs unguarded.
    #[test]
    fn a_work_lease_whose_init_frame_omits_the_engine_plugin_still_fails_the_assignment_by_name() {
        for (plugin, work_tools, auto, expected) in [
            (false, true, true, Some(ENGINE_PLUGIN_ABSENT)),
            (true, false, true, Some(WORK_TOOLS_ABSENT)),
            (true, true, false, Some(AUTOMATIC_PERMISSIONS_ABSENT)),
            (true, true, true, None),
        ] {
            let frame = work_init_frame(plugin, work_tools, auto);
            let (mut lease, root) = hand_built_work_lease(
                &format!("reported-{plugin}-{work_tools}-{auto}"),
                &one_turn_reporting(&frame),
            );
            // Before the turn there is nothing to report, so the binding gate is silent —
            // this is the same lease exercising both halves of the asymmetry in one test.
            assert!(
                lease.work_readiness_after_turn().is_err(),
                "an unreported fact is a refusal on the post-turn path"
            );
            lease.client.prompt("ready", &mut |_| {}).expect("the scripted turn should end");

            match expected {
                Some(sentence) => {
                    let after = lease.work_readiness_after_turn().expect_err("a reported absence must refuse");
                    assert!(after.to_string().contains(sentence), "{after}");
                    // The SAME sentence at the next binding, now that the fact is reported.
                    let refusal = lease.bind_work_assignment(&fixture_assignment()).unwrap_err().to_string();
                    assert!(
                        refusal.contains(sentence),
                        "a reported absence must refuse the binding too: {refusal}"
                    );
                }
                None => {
                    lease.work_readiness_after_turn().expect("a fully equipped lease must pass");
                    // And it still gets no further than the seat bind the fixture cannot do,
                    // which is what proves the readiness gate was the only thing in the way.
                    let refusal = lease.bind_work_assignment(&fixture_assignment()).unwrap_err().to_string();
                    assert!(refusal.contains("overwrite the CEO's own"), "{refusal}");
                }
            }
            drop(lease);
            let _ = std::fs::remove_dir_all(&root);
        }
    }

    /// The asymmetry, as the two pure functions rather than through a child process: the
    /// binding gate refuses a reported absence and nothing else; the post-turn gate refuses
    /// anything that is not a reported `Yes`. One fact decides both — the init frame arrives
    /// with the first turn — and the sentences are shared so they cannot drift apart.
    #[test]
    fn only_a_reported_absence_refuses_a_binding_and_silence_refuses_only_after_a_turn() {
        use InitFact::{No, NotYetReported, Yes};
        let facts = |plugin, tools, auto| {
            [(plugin, ENGINE_PLUGIN_ABSENT), (tools, WORK_TOOLS_ABSENT), (auto, AUTOMATIC_PERMISSIONS_ABSENT)]
        };

        // A fresh lease: nothing reported. The binding proceeds; the post-turn gate does not.
        let fresh = facts(NotYetReported, NotYetReported, NotYetReported);
        assert_eq!(work_binding_readiness_refusal(fresh), None);
        assert_eq!(work_turn_readiness_refusal(fresh), Some(ENGINE_PLUGIN_ABSENT));

        // A fully equipped lease: both gates silent.
        let ready = facts(Yes, Yes, Yes);
        assert_eq!(work_binding_readiness_refusal(ready), None);
        assert_eq!(work_turn_readiness_refusal(ready), None);

        // Each reported absence refuses BOTH gates, and with its own sentence — a shared
        // sentence table is worth nothing if a fact can pick up its neighbor's words.
        for (facts, expected) in [
            (facts(No, Yes, Yes), ENGINE_PLUGIN_ABSENT),
            (facts(Yes, No, Yes), WORK_TOOLS_ABSENT),
            (facts(Yes, Yes, No), AUTOMATIC_PERMISSIONS_ABSENT),
        ] {
            assert_eq!(work_binding_readiness_refusal(facts), Some(expected));
            assert_eq!(work_turn_readiness_refusal(facts), Some(expected));
        }

        // A reported absence outranks an unreported fact at the binding: the gate must not
        // fall silent just because something earlier in the list has said nothing.
        assert_eq!(work_binding_readiness_refusal(facts(NotYetReported, No, NotYetReported)), Some(WORK_TOOLS_ABSENT));
    }

    /// The plugin's name is written by `engine_profile.rs` into the manifest and asserted by
    /// this file against the wire. Two literals would be a schedule for them to disagree, and
    /// the disagreement is silent in the direction that matters: the check could only ever
    /// answer "absent", about a plugin sitting right there. That is not hypothetical — a
    /// readiness check answering a false absence is what refused every background job on
    /// 2026-09-18.
    #[test]
    fn the_engine_plugin_is_named_once_and_the_manifest_and_the_wire_check_share_it() {
        assert_eq!(crate::engine_profile::PLUGIN_NAME, "richos-app-engine");
        let listed = work_init_frame(true, true, true);
        let names: Vec<&str> = listed["plugins"].as_array().unwrap().iter()
            .filter_map(|p| p["name"].as_str()).collect();
        assert!(names.contains(&crate::engine_profile::PLUGIN_NAME), "{names:?}");
    }

    /// A work seat is never the CEO's, and is never bound against an engine that would
    /// silently write his row instead (spec §5.8/§5.8c). Both refusals are checked, and the
    /// engine-capability one is checked against a bridge that cannot answer at all — which
    /// is the ambiguity case, and it resolves to refusing.
    #[test]
    fn a_work_seat_is_refused_rather_than_written_onto_the_ceos_row() {
        let root = std::env::temp_dir().join(format!("seat-refusal-{}", uuid::Uuid::new_v4()));
        let bridge = fixture_bridge(&root);
        let ceo = bridge.bind_work_seat("depot", "thread", "session", "assign-7", crate::entity::PERSON_DEFAULT);
        assert!(ceo.is_err(), "a work seat was allowed to be the CEO's own");
        let shaped = bridge.bind_work_seat("depot", "thread", "session", "assign-7", "work seat with spaces");
        assert!(shaped.is_err());
        // The bridge points at nothing, so the capability probe cannot answer — and an
        // unanswerable probe refuses rather than binding.
        assert!(!bridge.supports_work_seats());
        let unknown = bridge.bind_work_seat("depot", "thread", "session", "assign-7", "work-seat-assign-7");
        assert!(unknown.is_err(), "a seat was bound against an engine that cannot hold one");
        assert!(unknown.unwrap_err().to_string().contains("overwrite the CEO's own"));
    }

    // ---- the undocumented flag, and the loud-failure contract -------------------------

    #[test]
    fn args_always_carry_the_permission_flag() {
        // THE structural guarantee §16 demands: there is no code path that drops
        // `--permission-prompt-tool stdio` and continues. `child_args` is a pure function
        // with no branches, so proving it here proves it everywhere.
        let args = child_args("sess-1");
        let i = args.iter().position(|a| a == PERMISSION_PROMPT_TOOL).expect("the flag must be present");
        assert_eq!(args[i + 1], "stdio", "and it must be armed with `stdio`");
        // The flags the rest of this file depends on, pinned so a tidy-up cannot quietly
        // remove one. Each has a stated reason on `child_args`.
        for required in [
            "--print",
            "--input-format=stream-json",
            "--output-format=stream-json",
            "--include-partial-messages",
            "--verbose",
            "--no-session-persistence",
            "--session-id",
        ] {
            assert!(args.iter().any(|a| a == required), "missing {required}");
        }
        // The session id is OURS and is passed through, which is what makes `session_id()`
        // answerable before the first turn.
        let j = args.iter().position(|a| a == "--session-id").unwrap();
        assert_eq!(args[j + 1], "sess-1");
        // And no environment variable can turn the flag off: `child_args` reads none.
        std::env::set_var("RICHOS_PERMISSION_PROMPT_TOOL", "");
        assert!(child_args("x").iter().any(|a| a == PERMISSION_PROMPT_TOOL));
        std::env::remove_var("RICHOS_PERMISSION_PROMPT_TOOL");
    }

    // ---- the standing instruction (doctrine.rs, inner-doctrine design §7.1/§7.2) --------

    #[test]
    fn chat_args_always_carry_the_doctrine_flag() {
        // The same structural guarantee as the permission flag, for the same reason: there is
        // no code path that drops `--append-system-prompt-file` and continues. `chat_child_args`
        // is a pure function with no branches, so proving it here proves it everywhere.
        let doctrine = Path::new("/Users/example/Library/Application Support/com.richos.app/inner-doctrine.md");
        let skills = Path::new("/Users/example/Library/Application Support/com.richos.app/rich-skills");
        let args = chat_child_args("sess-1", doctrine, skills);
        let i = args
            .iter()
            .position(|a| a == APPEND_SYSTEM_PROMPT_FILE)
            .expect("the chat lease must always carry the standing instruction");
        assert_eq!(args[i + 1], doctrine.display().to_string(), "and it must name the rendered file");

        // The base vector survives underneath it — a doctrine that arrived by dropping the
        // permission channel would be a bad trade.
        assert!(args.iter().any(|a| a == PERMISSION_PROMPT_TOOL));
        let j = args.iter().position(|a| a == "--setting-sources").unwrap();
        assert_eq!(args[j + 1], "", "--setting-sources '' stays exactly as it was (native.rs:316-317)");

        // A path with spaces in it needs no treatment at all: `Command::args` hands a vector
        // to `execve` with no shell in between. `Application Support` has a space in it, so
        // this is the production case and not a hypothetical one.
        assert!(args[i + 1].contains("Application Support"));

        // And no environment variable can turn it off: `chat_child_args` reads none.
        std::env::set_var("RICHOS_APPEND_SYSTEM_PROMPT_FILE", "");
        std::env::set_var("RICHOS_DOCTRINE", "");
        assert!(chat_child_args("x", doctrine, skills).iter().any(|a| a == APPEND_SYSTEM_PROMPT_FILE));
        std::env::remove_var("RICHOS_APPEND_SYSTEM_PROMPT_FILE");
        std::env::remove_var("RICHOS_DOCTRINE");
    }

    #[test]
    fn the_conversation_asks_for_resident_tools_and_the_work_lease_asks_for_nothing() {
        // THE PIN FOR `TOOL_SEARCH_ENV`. A pure function, so this proves it for every spawn
        // rather than for one: `spawn_with_tools` has no branch that can drop it.
        assert_eq!(
            tool_residency_env(LeaseRole::Conversation),
            Some(("ENABLE_TOOL_SEARCH", "false")),
            "the front desk must not have to DISCOVER the register before it can call it"
        );
        // Spelled out rather than compared to the constants, because the value is the one
        // thing here the shipped binary parses: `To()` accepts 0/false/no/off and nothing
        // else, so a value edited to `"0"` is fine and one edited to `"off "` with a space is
        // too (it trims) — but one edited to `"disabled"` would silently mean DEFERRAL ON.
        assert_eq!(TOOL_SEARCH_OFF, "false");
        assert_eq!(
            tool_residency_env(LeaseRole::Work),
            None,
            "nothing has been measured on the work lease, so nothing is changed there"
        );
    }

    #[test]
    fn a_deferring_session_is_read_off_the_child_s_own_inventory() {
        // The POSITIVE CONTROL for the loudness layer. The negative alone — no `ToolSearch`
        // in a frame — passes just as well when the reading is broken, which is the failure
        // `feedback_negative_tests_pass_for_wrong_reason` names.
        let deferring = json!({"type":"system","subtype":"init",
            "tools":["Read","Bash","ToolSearch","mcp__richos_assignments__record"]});
        assert_eq!(tool_search_from_init(&deferring), InitFact::Yes);

        let resident = json!({"type":"system","subtype":"init",
            "tools":["Read","Bash","mcp__richos_assignments__record","mcp__richos_continuity__checkpoint"]});
        assert_eq!(tool_search_from_init(&resident), InitFact::No);

        // **AND THE TRAP THIS FACT EXISTS FOR.** Both frames list the register, so every
        // init fact the app already reads is identical between them — `loaded_from_init` was
        // `true` on the very run whose model spent 7.5 s discovering that same tool.
        for frame in [&deferring, &resident] {
            assert!(crate::assignment_tools::loaded_from_init(frame),
                "the register is listed either way; that is why it cannot answer this question");
        }

        // A frame with no `tools` key at all is `No` and not a panic: it is a statement that
        // the child offered no discovery tool, which is what the reading claims.
        assert_eq!(tool_search_from_init(&json!({"type":"system","subtype":"init"})), InitFact::No);
    }

    #[test]
    fn the_doctrine_never_reaches_the_base_vector() {
        // Only the conversation argument vector carries the standing instruction.
        for args in [child_args("s")] {
            assert!(
                !args.iter().any(|a| a == APPEND_SYSTEM_PROMPT_FILE),
                "the doctrine leaked into a non-chat argument vector: {args:?}"
            );
        }
    }

    #[test]
    fn a_missing_doctrine_fails_loudly_and_names_the_path() {
        // THE FAILURE PATH THAT MAKES THIS CHANNEL WORTH CHOOSING. Under the rejected
        // `--setting-sources project` candidate an absent instruction file is a successful
        // handshake and a generic Claude; here it is a refusal, before the process exists.
        // The binary below is PRESENT and executable and the working directory EXISTS, so the
        // only fault is the doctrine — which is what makes the variant meaningful.
        let script = write_script("doctrine-missing", "exit 0\n");
        let absent = std::env::temp_dir().join(format!("richos-no-doctrine-{}.md", uuid::Uuid::new_v4().simple()));
        assert!(!absent.exists());

        let err = NativeClient::spawn(&script, Path::new("/tmp"), &absent, &skills_fixture())
            .err()
            .expect("a missing standing instruction must never be a degraded success");
        let msg = err.to_string();
        assert!(matches!(err, NativeError::DoctrineMissing { .. }), "{msg}");
        assert!(msg.contains(&absent.display().to_string()), "the failure must name the file: {msg}");
        assert!(msg.contains("not Rich"), "the failure must say what is at stake: {msg}");
        assert!(!msg.contains("claude binary was not found"), "reported as the wrong fault: {msg}");
    }

    #[test]
    fn an_empty_doctrine_is_a_refusal_and_not_an_empty_instruction() {
        // `claude` ACCEPTS a zero-byte file, so this one is ours to catch: it would hand the
        // CEO a generic assistant behind a clean handshake.
        let script = write_script("doctrine-empty", "exit 0\n");
        let empty = script.parent().unwrap().join("inner-doctrine.md");
        std::fs::write(&empty, b"").unwrap();
        let err = NativeClient::spawn(&script, Path::new("/tmp"), &empty, &skills_fixture()).err().expect("empty is not instruction");
        assert!(matches!(err, NativeError::DoctrineMissing { .. }), "{err}");
        assert!(err.to_string().contains("empty"), "{err}");
    }

    #[test]
    fn a_directory_where_the_doctrine_should_be_says_so_rather_than_saying_it_is_absent() {
        let script = write_script("doctrine-is-a-dir", "exit 0\n");
        let dir = script.parent().unwrap().join("inner-doctrine.md.dir");
        std::fs::create_dir_all(&dir).unwrap();
        let err = NativeClient::spawn(&script, Path::new("/tmp"), &dir, &skills_fixture()).err().expect("a directory is not a doctrine");
        assert!(matches!(err, NativeError::DoctrineMissing { .. }), "{err}");
        assert!(err.to_string().contains("not a file"), "{err}");
    }

    // ---- the skills (skills.rs; measured in inner-doctrine-skills-2026-09-06/) -----------

    #[test]
    fn chat_args_always_carry_the_skills_flag() {
        let doctrine = Path::new("/Users/example/Library/Application Support/com.richos.app/inner-doctrine.md");
        let skills = Path::new("/Users/example/Library/Application Support/com.richos.app/rich-skills");
        let args = chat_child_args("sess-1", doctrine, skills);
        let i = args
            .iter()
            .position(|a| a == PLUGIN_DIR)
            .expect("the chat lease must always carry RichOS's own skills");
        assert_eq!(args[i + 1], skills.display().to_string());
        // The directory is the APP's, not the operator's `~/.claude` and not the visited
        // folder. The CEO ruled that authority comes from what RichOS writes.
        assert!(args[i + 1].contains("com.richos.app"), "{:?}", args[i + 1]);
        assert!(!args[i + 1].contains("/.claude/"), "the operator's own directory is not a source of authority");

        // And no environment variable turns it off: `chat_child_args` reads none.
        std::env::set_var("RICHOS_PLUGIN_DIR", "");
        std::env::set_var("RICHOS_SKILLS", "");
        assert!(chat_child_args("x", doctrine, skills).iter().any(|a| a == PLUGIN_DIR));
        std::env::remove_var("RICHOS_PLUGIN_DIR");
        std::env::remove_var("RICHOS_SKILLS");
    }

    #[test]
    fn the_skills_never_reach_the_base_vector() {
        for args in [child_args("s")] {
            assert!(
                !args.iter().any(|a| a == PLUGIN_DIR),
                "RichOS's skills leaked into a non-chat argument vector: {args:?}"
            );
        }
    }

    /// **THE ONE THAT MATTERS MOST, because the binary will not do it for us.** Measured (cell
    /// K4): `--plugin-dir` naming a path that is not there exits 0 with a clean handshake and
    /// `plugins: []`. Without this check, deleting a skill file would be a product that is
    /// quietly less than it says it is.
    #[test]
    fn a_missing_skill_fails_loudly_and_names_the_file() {
        let script = write_script("skills-missing", "exit 0\n");
        let absent = std::env::temp_dir().join(format!("richos-no-skills-{}", uuid::Uuid::new_v4().simple()));
        assert!(!absent.exists());

        let err = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &absent)
            .err()
            .expect("a missing skill must never be a degraded success");
        let msg = err.to_string();
        assert!(matches!(err, NativeError::SkillsMissing { .. }), "{msg}");
        assert!(msg.contains("plugin.json"), "the failure must name the file it looked for: {msg}");
        assert!(
            msg.contains("without saying so"),
            "the failure must say WHY we check rather than leaving it to the binary: {msg}"
        );
        assert!(!msg.contains("claude binary was not found"), "reported as the wrong fault: {msg}");
    }

    #[test]
    fn a_skill_file_that_was_emptied_is_a_refusal_too() {
        let script = write_script("skills-empty", "exit 0\n");
        let root = skills_fixture();
        std::fs::write(crate::skills::skill_path(&root, "american-english"), b"").unwrap();
        let err = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &root)
            .err()
            .expect("an empty skill is no skill");
        assert!(matches!(err, NativeError::SkillsMissing { .. }), "{err}");
        assert!(err.to_string().contains("empty"), "{err}");
    }

    /// The second layer, in a unit test rather than a live one: a lease that has run no turn
    /// has heard nothing, and that is its own state.
    #[test]
    fn a_fresh_lease_reports_the_skills_verdict_as_not_yet_reported() {
        let script = write_script(
            "verdict",
            "read -r line\n\
             printf '%s\\n' '{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"req_init\",\"response\":{}}}'\n\
             sleep 5\n",
        );
        let client = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture())
            .expect("the handshake should succeed");
        assert_eq!(
            client.skills_verdict(),
            crate::skills::SkillsVerdict::NotYetReported,
            "the init frame arrives with the first TURN; before that we have been told nothing"
        );
    }

    #[test]
    fn the_real_reader_verifies_both_onboarding_tools_from_the_first_init() {
        use crate::onboarding_tools::{OnboardingToolsVerdict, QUALIFIED_SAVE_TOOL, QUALIFIED_DECLINE_TOOL};
        for (suffix, names, expected) in [
            ("present", vec![QUALIFIED_SAVE_TOOL, QUALIFIED_DECLINE_TOOL], OnboardingToolsVerdict::Loaded),
            ("missing-decline", vec![QUALIFIED_SAVE_TOOL], OnboardingToolsVerdict::Rejected),
            ("lookalike", vec!["mcp__other__save_company_notes", QUALIFIED_DECLINE_TOOL], OnboardingToolsVerdict::Rejected),
        ] {
            let init = json!({"type":"system","subtype":"init","tools":names,"plugins":[{"name":"rich-skills"}]}).to_string();
            let body = format!(
                "read -r line\nprintf '%s\\n' '{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"success\",\"request_id\":\"req_init\",\"response\":{{}}}}}}'\n\
                 read -r line\nprintf '%s\\n' '{init}'\n\
                 printf '%s\\n' '{{\"type\":\"result\",\"subtype\":\"success\",\"stop_reason\":\"end_turn\"}}'\n\
                 while read -r line; do :; done\n"
            );
            let script = write_script(&format!("onboarding-tools-{suffix}"), &body);
            let client = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()).unwrap();
            assert_eq!(client.onboarding_tools_verdict(), OnboardingToolsVerdict::NotYetReported);
            assert!(client.ensure_onboarding_tools_loaded().is_err());
            client.prompt("ready", &mut |_| {}).unwrap();
            assert_eq!(client.onboarding_tools_verdict(), expected);
            assert_eq!(client.ensure_onboarding_tools_loaded().is_ok(), expected == OnboardingToolsVerdict::Loaded);
        }
    }

    // ---- resolving `claude` itself (the 2026-09-17 candidate-walk defect) --------------
    //
    // Every test here drives `search_claude_bin` with an INJECTED `ClaudeBinEnv` rather than
    // mutating this process's real `$HOME`/`$HOMEBREW_PREFIX`/`~/.npmrc` — the same reason
    // `setup.rs::SetupPaths` is injected rather than read, and it is what keeps these
    // deterministic under `cargo test`'s parallel threads and honest about a machine that
    // happens to have a real Homebrew or npm install sitting on it.

    #[test]
    fn search_claude_bin_finds_a_homebrew_style_install() {
        let dir = std::env::temp_dir().join(format!("richos-claude-bin-brew-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(dir.join("bin")).unwrap();
        let bin = dir.join("bin/claude");
        std::fs::write(&bin, "#!/bin/sh\n").unwrap();
        let env = ClaudeBinEnv { homebrew_prefixes: vec![dir.display().to_string()], ..Default::default() };
        let found = search_claude_bin(&env).expect("a Homebrew-style install must resolve");
        assert_eq!(found, bin);
    }

    #[test]
    fn search_claude_bin_finds_an_npm_global_prefix_install() {
        let dir = std::env::temp_dir().join(format!("richos-claude-bin-npm-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(dir.join("bin")).unwrap();
        let bin = dir.join("bin/claude");
        std::fs::write(&bin, "#!/bin/sh\n").unwrap();
        let env = ClaudeBinEnv { npm_prefix: Some(dir.display().to_string()), ..Default::default() };
        let found = search_claude_bin(&env).expect("an npm global prefix install must resolve");
        assert_eq!(found, bin);
    }

    #[test]
    fn search_claude_bin_still_finds_the_installer_launcher_at_home_local_bin() {
        // POSITIVE CONTROL: the ordinary, already-working case, unchanged by everything else
        // added around it.
        let home = std::env::temp_dir().join(format!("richos-claude-bin-home-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(home.join(".local/bin")).unwrap();
        let bin = home.join(".local/bin/claude");
        std::fs::write(&bin, "#!/bin/sh\n").unwrap();
        let env = ClaudeBinEnv { home: Some(home.display().to_string()), ..Default::default() };
        let found = search_claude_bin(&env).expect("the installer's own launcher must still resolve");
        assert_eq!(found, bin);
    }

    #[test]
    fn search_claude_bin_lets_an_explicit_override_win_even_over_a_real_install() {
        let dir = std::env::temp_dir().join(format!("richos-claude-bin-explicit-{}", uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        let winner = dir.join("winner");
        std::fs::write(&winner, "#!/bin/sh\n").unwrap();
        // A decoy that WOULD resolve if the override were not exclusive.
        let decoy_home = dir.join("home");
        std::fs::create_dir_all(decoy_home.join(".local/bin")).unwrap();
        std::fs::write(decoy_home.join(".local/bin/claude"), "#!/bin/sh\n").unwrap();
        let env = ClaudeBinEnv {
            explicit: Some(winner.display().to_string()),
            home: Some(decoy_home.display().to_string()),
            ..Default::default()
        };
        let found = search_claude_bin(&env).expect("the explicit override exists and must win");
        assert_eq!(found, winner);
    }

    #[test]
    fn search_claude_bin_refuses_by_name_when_found_nowhere() {
        let env = ClaudeBinEnv {
            home: Some("/nonexistent/richos-test-home".into()),
            homebrew_prefixes: vec!["/nonexistent/richos-test-homebrew".into()],
            npm_prefix: Some("/nonexistent/richos-test-npm".into()),
            ..Default::default()
        };
        let looked = search_claude_bin(&env).expect_err("nothing here should resolve");
        assert!(looked.iter().any(|p| p.contains("richos-test-home/.local/bin/claude")), "{looked:?}");
        assert!(looked.iter().any(|p| p.contains("richos-test-homebrew/bin/claude")), "{looked:?}");
        assert!(looked.iter().any(|p| p.contains("richos-test-npm/bin/claude")), "{looked:?}");
        assert_eq!(looked.len(), 3, "every place looked is named, and only those: {looked:?}");
    }

    #[test]
    fn resolve_claude_bin_checked_names_every_place_looked_when_nothing_is_found() {
        // Same claim through the public, `NativeError`-carrying entry point `main.rs` boot
        // actually calls — proven against a `ClaudeBinEnv` that cannot find its own explicit
        // override, so the exclusive-return path is exercised too.
        let looked = vec!["/a".to_string(), "/b".to_string()];
        let err = NativeError::ClaudeNotFound { looked: looked.join("; ") };
        let msg = err.to_string();
        assert!(msg.contains("/a; /b"), "{msg}");
        assert!(msg.contains("install Claude Code"), "{msg}");
    }

    #[test]
    fn a_missing_binary_fails_loudly_and_names_the_path() {
        let err = NativeClient::spawn(Path::new("/nonexistent/definitely/not/claude"), Path::new("/tmp"), &doctrine_fixture(), &skills_fixture())
            .err()
            .expect("a missing binary must not be a degraded success");
        match &err {
            NativeError::BinaryMissing { path } => assert!(path.contains("not/claude")),
            other => panic!("expected BinaryMissing, got {other:?}"),
        }
        // The message a human sees says what is wrong and why it matters.
        assert!(err.to_string().contains("cannot run without it"), "{err}");
    }

    #[test]
    fn a_missing_working_directory_is_never_reported_as_a_missing_binary() {
        // RED-FIRST PROOF of the defect measured on 2026-09-01: the binary below is PRESENT
        // and EXECUTABLE, and only the working directory is absent. `Command::current_dir`
        // on a missing directory fails ENOENT, and ENOENT was mapped to BinaryMissing — so
        // the app announced a missing binary while that binary sat on disk.
        let script = write_script("cwd-missing", "exit 0\n");
        assert!(script.exists(), "the binary must be present for this test to mean anything");
        let missing = std::env::temp_dir().join(format!("richos-no-such-engine-{}", uuid::Uuid::new_v4().simple()));
        assert!(!missing.exists());

        let err = NativeClient::spawn(&script, &missing, &doctrine_fixture(), &skills_fixture())
            .err()
            .expect("a missing working directory must not be a degraded success");
        let msg = err.to_string();
        assert!(!msg.contains("claude binary was not found"), "a missing working directory reported as a missing binary: {msg}");
        assert!(msg.contains(&missing.display().to_string()), "the failure must name the directory that is actually missing: {msg}");
        assert!(matches!(err, NativeError::WorkingDirMissing { .. }), "{msg}");
    }

    #[test]
    fn an_engine_path_that_is_a_file_says_so_rather_than_saying_it_is_absent() {
        // ENOTDIR, not ENOENT: the operator can SEE the path, so "it does not exist" would be
        // a false sentence about something in front of him.
        let script = write_script("cwd-not-a-dir", "exit 0\n");
        let file = script.parent().unwrap().join("engine-that-is-a-file");
        std::fs::write(&file, b"not a directory").unwrap();

        let err = NativeClient::spawn(&script, &file, &doctrine_fixture(), &skills_fixture()).err().expect("a file is not a working directory");
        let msg = err.to_string();
        assert!(matches!(err, NativeError::WorkingDirNotADirectory { .. }), "{msg}");
        assert!(msg.contains("is not a directory"), "{msg}");
        assert!(msg.contains(&file.display().to_string()), "{msg}");
    }

    #[test]
    fn a_binary_that_is_present_but_not_executable_is_not_reported_as_missing() {
        // The third fault the old single-variant mapping flattened: the file IS installed, so
        // "install Claude Code" is the wrong instruction and `chmod` is the right one.
        let script = write_script("not-executable", "exit 0\n");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o644)).unwrap();
        }
        let err = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()).err().expect("an unrunnable binary must fail");
        let msg = err.to_string();
        assert!(matches!(err, NativeError::BinaryNotExecutable { .. }), "{msg}");
        assert!(!msg.contains("was not found"), "a present file must never be reported as absent: {msg}");
        assert!(msg.contains("644"), "the diagnosis names the mode it actually found: {msg}");
    }

    #[test]
    fn with_both_missing_the_binary_is_named_first_and_that_order_is_deliberate() {
        // Multi-fault installs get the FIRST true sentence, not a false one: the 197 MB
        // install is upstream of the engine directory, so it is the one named. Pinned here so
        // the order is a decision on the record rather than an accident of code layout.
        let missing_dir = std::env::temp_dir().join(format!("richos-no-such-engine-{}", uuid::Uuid::new_v4().simple()));
        let err = NativeClient::spawn(Path::new("/nonexistent/definitely/not/claude"), &missing_dir, &doctrine_fixture(), &skills_fixture())
            .err()
            .expect("must fail");
        assert!(matches!(err, NativeError::BinaryMissing { .. }), "{err}");
    }

    #[test]
    fn a_child_that_rejects_the_flag_fails_loudly_and_quotes_its_own_stderr() {
        // The measured failure mode, reproduced without needing the real binary: on an
        // unknown option `claude` writes ONE line to stderr and exits 1 with zero bytes of
        // stdout (verified 2026-08-31 against 2.1.252). This script does exactly that.
        //
        // THE SENTENCE BELOW IS NOW STABLE, AND IT WAS NOT. Whether this process gets its
        // handshake into the pipe before a child this short-lived is torn down is a race
        // this machine wins and a GitHub runner lost — see `handshake()`. The product now
        // collapses both arms onto one diagnosis, so this assertion is a claim about the
        // product rather than about the scheduler. `write_failure_reason` is where both arms
        // are proved without needing to win anything.
        let script = write_script(
            "flag-reject",
            "echo \"error: unknown option '--permission-prompt-tool'\" >&2\nexit 1\n",
        );
        let err = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture())
            .err()
            .expect("a rejected flag must never be a silent degrade");
        let msg = err.to_string();
        assert!(matches!(err, NativeError::Startup { .. }), "{msg}");
        assert!(msg.contains("exited before answering the handshake"), "{msg}");
        // The child's own words, verbatim — on this failure that one line IS the diagnosis.
        assert!(msg.contains("unknown option '--permission-prompt-tool'"), "{msg}");
    }

    #[test]
    fn one_failed_handshake_write_gets_one_sentence_whichever_side_of_the_race_we_land_on() {
        // THE ARM A RUNNER TOOK AND THIS MACHINE NEVER DOES. The test above can only
        // exercise whichever side of the race it happens to land on, which is why it passed
        // here for days and failed on the first public runner. These three assertions need
        // no child, no timing and no luck.
        let pipe = NativeError::Io(std::io::Error::from(std::io::ErrorKind::BrokenPipe));

        // Broken pipe, child confirmed gone: the SAME words the read side uses, because it
        // is the same fact.
        assert_eq!(
            NativeClient::write_failure_reason(&pipe, true, true),
            "the child exited before answering the handshake"
        );

        // Broken pipe, child still up: a different fault, and it says so rather than
        // claiming an exit nobody observed.
        let live = NativeClient::write_failure_reason(&pipe, true, false);
        assert!(live.contains("closed its input"), "{live}");
        assert!(!live.contains("exited"), "an unobserved exit was asserted as fact: {live}");

        // Anything else keeps the error verbatim — collapsing every write failure onto one
        // sentence would be the opposite mistake.
        let other = NativeError::Io(std::io::Error::from(std::io::ErrorKind::PermissionDenied));
        let msg = NativeClient::write_failure_reason(&other, false, false);
        assert!(msg.starts_with("could not write the initialize handshake:"), "{msg}");
    }

    #[test]
    fn a_child_that_never_answers_the_handshake_times_out_rather_than_hanging() {
        // A binary that starts, holds stdio open and says nothing is the failure that would
        // otherwise hang the app forever at boot. Bounded by RICHOS_HANDSHAKE overridden
        // here through the script instead: the script exits after a moment, which is the
        // Disconnected arm; the Timeout arm is bounded by HANDSHAKE_TIMEOUT and is not worth
        // 30 s of test time to exercise.
        let script = write_script("silent", "sleep 0.3\nexit 0\n");
        let err = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()).err().expect("silence is not success");
        assert!(matches!(err, NativeError::Startup { .. }), "{err}");
    }

    #[test]
    fn a_pending_initialize_handshake_is_cancellable() {
        let script = write_script("cancel-handshake", r#"
count=0
while IFS= read -r line; do
  case "$line" in
    *'"subtype":"initialize"'*)
      count=$((count + 1))
      if [ "$count" -eq 1 ]; then
        printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"req_init","response":{}}}'
      fi
      ;;
  esac
done
"#);
        let mut client = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()).unwrap();
        let root = std::env::temp_dir().join(format!("richos-handshake-stop-{}", uuid::Uuid::new_v4()));
        let control = crate::steering::TurnControl::open(&root).unwrap();
        control.begin_turn(crate::steering::ActiveTurn {
            turn_id: "initial-request".into(), thread_id: "thread".into(),
            entity_id: None, started_at: None,
        });
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let worker_control = control.clone();
        let worker = std::thread::spawn(move || {
            entered_tx.send(()).unwrap();
            client.handshake_cancellable(Some(&worker_control))
        });
        entered_rx.recv_timeout(std::time::Duration::from_secs(5)).unwrap();
        let began = std::time::Instant::now();
        control.request_stop().unwrap();
        let error = worker.join().unwrap().unwrap_err();
        assert!(error.to_string().contains("stopped at your request"), "{error}");
        assert!(began.elapsed() < std::time::Duration::from_secs(2));
    }

    #[test]
    fn a_healthy_handshake_yields_a_client_whose_session_id_is_known_immediately() {
        // The session id is ours (`--session-id`), so it is answerable before any turn —
        // which is what `ledger.rs`'s rotation records need.
        let script = write_script(
            "ok",
            "read -r line\n\
             printf '%s\\n' '{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"req_init\",\"response\":{\"account\":{\"email\":\"x@y\"}}}}'\n\
             sleep 5\n",
        );
        let client = match NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()) {
            Ok(c) => c,
            Err(e) => panic!("handshake should have succeeded: {e}"),
        };
        assert_eq!(client.session_id().len(), 36, "a uuid, hyphenated, as --session-id requires");
        assert!(client.session_id().contains('-'));
    }

    /// A rendered standing instruction on disk, for the spawn tests.
    ///
    /// The REAL renderer, not a stub file: these tests then fail if `doctrine.rs` ever stops
    /// producing something `preflight` will accept, which is the only way the two halves of
    /// this feature can be checked against each other without a live binary.
    /// A rendered SKILL PLUGIN on disk, for the spawn tests. The real renderer again, so a
    /// `skills.rs` that stopped producing something `preflight` accepts breaks these too.
    fn skills_fixture() -> std::path::PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("richos-skills-fixture-{}", uuid::Uuid::new_v4().simple()));
        crate::skills::ensure_rendered(&dir).expect("the skills fixture must render")
    }

    fn doctrine_fixture() -> std::path::PathBuf {
        let dir = std::env::temp_dir()
            .join(format!("richos-doctrine-fixture-{}", uuid::Uuid::new_v4().simple()));
        crate::doctrine::ensure_rendered(&dir, &crate::doctrine::DoctrineIdentity::default())
            .expect("the doctrine fixture must render")
    }

    fn write_script(name: &str, body: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("richos-native-{}-{}", name, uuid::Uuid::new_v4().simple()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("fake-claude");
        std::fs::write(&path, format!("#!/bin/sh\n{body}")).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        path
    }

    #[test]
    fn hidden_context_denies_permission_then_visible_delivery_restores_normal_policy() {
        let script = write_script("context-only-permissions", r#"
read -r init
printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"req_init","response":{}}}'
for expected in deny allow; do
  read -r prompt
  printf '%s\n' '{"type":"control_request","request_id":"tool-permission","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"touch should-not-run"}}}'
  read -r answer
  case "$answer" in
    *\"behavior\":\"$expected\"*) ;;
    *) exit 9 ;;
  esac
  printf '%s\n' '{"type":"result","stop_reason":"end_turn"}'
done
"#);
        let mut client = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()).unwrap();
        assert_eq!(client.prompt_context_only("Only context", &mut |_| {}).unwrap(), "end_turn");
        assert!(!client.reader_state.lock().unwrap().context_only);
        assert_eq!(client.prompt("Actual visible request", &mut |_| {}).unwrap(), "end_turn");
    }

    #[test]
    fn the_checkpoint_is_refused_until_he_has_heard_something_and_refused_again_next_turn() {
        // **THE ENFORCEMENT THE DOCTRINE SENTENCE COULD NOT BE.** Run 2 of
        // `docs/verification/question-receipt-2026-09-18.md` spent 12.980 s -> 17.023 s of a
        // 22.956 s wait on a `checkpoint` written before his first word, with the doctrine
        // already asking for the reply first. So the order is a condition of the tool working.
        //
        // The fixture child asserts the behavior it receives and exits 9 if it is wrong, so a
        // gate that silently stopped working fails this test rather than passing it quietly.
        //
        // **Four facts, and the fourth is the one an obvious implementation gets wrong:**
        // deny before a word; allow after a word; `inspect` is never gated; and the NEXT turn
        // starts refused again, because `spoken_this_turn` is reset with the send.
        let script = write_script("checkpoint-after-the-reply", r#"
read -r init
printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"req_init","response":{}}}'
read -r prompt
printf '%s\n' '{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"mcp__richos_continuity__checkpoint","input":{}}}'
read -r answer
case "$answer" in *\"behavior\":\"deny\"*) ;; *) exit 9 ;; esac
printf '%s\n' '{"type":"control_request","request_id":"p2","request":{"subtype":"can_use_tool","tool_name":"mcp__richos_continuity__inspect","input":{}}}'
read -r answer
case "$answer" in *\"behavior\":\"allow\"*) ;; *) exit 8 ;; esac
printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"On it!"}}}'
printf '%s\n' '{"type":"control_request","request_id":"p3","request":{"subtype":"can_use_tool","tool_name":"mcp__richos_continuity__checkpoint","input":{}}}'
read -r answer
case "$answer" in *\"behavior\":\"allow\"*) ;; *) exit 7 ;; esac
printf '%s\n' '{"type":"result","stop_reason":"end_turn"}'
read -r prompt
printf '%s\n' '{"type":"control_request","request_id":"p4","request":{"subtype":"can_use_tool","tool_name":"mcp__richos_continuity__checkpoint","input":{}}}'
read -r answer
case "$answer" in *\"behavior\":\"deny\"*) ;; *) exit 6 ;; esac
printf '%s\n' '{"type":"result","stop_reason":"end_turn"}'
"#);
        let client = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()).unwrap();
        let mut said = String::new();
        let mut permissions = Vec::new();
        {
            let mut collect = |item: TurnItem| match item {
                TurnItem::Text { text, .. } => said.push_str(text),
                TurnItem::Machinery(record) => {
                    if record.kind == crate::machinery::MachineryKind::PermissionRequested {
                        permissions.push(record.title.clone());
                    }
                }
            };
            assert_eq!(client.prompt("Land the pricing branch", &mut collect).unwrap(), "end_turn");
        }
        assert_eq!(said, "On it!");
        // The refusal is MACHINERY and never his words — it is on the technical view's lane,
        // beside the two that were allowed, and nothing about it reaches the conversation.
        assert_eq!(permissions.len(), 3, "{permissions:?}");
        assert!(!said.contains("Not yet"), "a refusal aimed at the model must never be shown to him");

        // And the second turn, whose only job is to prove the per-turn reset exists: the
        // child exits 6 if the checkpoint it tries before speaking is allowed on the strength
        // of the PREVIOUS turn's reply.
        assert_eq!(client.prompt("And the second thing", &mut |_| {}).unwrap(), "end_turn");
    }

    /// One turn of a front desk that hands work over, as the wire actually carries it.
    ///
    /// `receipt` is the `tool_result` content the register answers with, and `after` is whatever
    /// the model says once it has been handed that answer — the two variables this behavior is
    /// entirely about.
    fn a_handover_turn(tag: &str, call_id: &str, receipt: &str, error: bool, after: &str) -> Vec<TurnItem2> {
        let script = write_script(tag, &format!(r#"
read -r init
printf '%s\n' '{{"type":"control_response","response":{{"subtype":"success","request_id":"req_init","response":{{}}}}}}'
read -r prompt
printf '%s\n' '{{"type":"stream_event","event":{{"type":"message_start"}}}}'
printf '%s\n' '{{"type":"stream_event","event":{{"type":"content_block_start","content_block":{{"type":"tool_use","id":"{call_id}","name":"mcp__richos_assignments__record","input":{{}}}}}}}}'
printf '%s\n' '{{"type":"assistant","message":{{"content":[{{"type":"tool_use","id":"{call_id}","name":"mcp__richos_assignments__record","input":{{"assignment":"Land the pricing branch","kind":"task"}}}}]}}}}'
printf '%s\n' '{{"type":"user","message":{{"content":[{{"type":"tool_result","tool_use_id":"{call_id}","is_error":{error},"content":"{receipt}"}}]}}}}'
printf '%s\n' '{{"type":"stream_event","event":{{"type":"content_block_delta","delta":{{"type":"text_delta","text":"{after}"}}}}}}'
printf '%s\n' '{{"type":"result","stop_reason":"end_turn"}}'
"#));
        let client = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()).unwrap();
        let mut log = Vec::new();
        {
            let mut collect = |item: TurnItem| match item {
                TurnItem::Text { text, .. } => log.push(TurnItem2::Said(text.to_string())),
                TurnItem::Machinery(record) => log.push(TurnItem2::Machinery(
                    record.kind,
                    record.title.clone(),
                    record.summary.clone().unwrap_or_default(),
                )),
            };
            assert_eq!(client.prompt("Land the pricing branch", &mut collect).unwrap(), "end_turn");
        }
        log
    }

    /// An owned, comparable copy of what the turn delivered — `TurnItem` borrows its text.
    #[derive(Debug, PartialEq)]
    enum TurnItem2 {
        Said(String),
        Machinery(crate::machinery::MachineryKind, String, String),
    }

    #[test]
    fn the_app_says_the_register_s_words_at_the_register_s_return_and_he_never_reads_them_twice() {
        // **THE CEO'S §55, AND THE ROUND TRIP NOTHING IN THE FRONT DESK COULD REMOVE.** Run 3 of
        // `docs/verification/first-reply-2026-09-18.md` measured his first words at 7.128 s warm,
        // of which the last 1.094 s was the model saying back to the app the four words the app
        // had just handed it. This test is the wire proof that the app now says them itself, at
        // the tool result, and that the model's copy reaches him nowhere.
        let receipt = r#"{\"recorded\":true,\"say\":\"On it!\"}"#;
        let log = a_handover_turn("receipt-spoken-by-the-app", "toolu_R", receipt, false, "On it!");

        // Exactly ONE run of prose, and it is the register's sentence.
        let said: Vec<&String> = log.iter().filter_map(|i| match i { TurnItem2::Said(t) => Some(t), _ => None }).collect();
        assert_eq!(said, vec!["On it!"], "he must be told once, by the app: {log:#?}");

        // **AND IT CAME OFF THE TOOL RESULT, NOT OFF THE MODEL'S LATER DELTA.** The ordering is
        // the evidence: the app's text is delivered BEFORE the machinery record that closes the
        // register's row, which is built from the very frame the sentence was read out of.
        let words = log.iter().position(|i| matches!(i, TurnItem2::Said(t) if t == "On it!")).unwrap();
        let closed = log
            .iter()
            .position(|i| matches!(i, TurnItem2::Machinery(kind, title, summary)
                if *kind == crate::machinery::MachineryKind::ToolCall
                    && title.is_empty()
                    && summary.contains("recorded")))
            .unwrap_or_else(|| panic!("the register's closing record is not here: {log:#?}"));
        assert!(words < closed, "the app must speak as the result goes past, not after it: {log:#?}");

        // The register's own row is still fully reported — the conversation gained a line, the
        // technical lane lost nothing.
        assert!(log.iter().any(|i| matches!(i, TurnItem2::Machinery(_, title, _)
            if title == crate::assignment_tools::QUALIFIED_RECORD_TOOL)), "{log:#?}");
    }

    #[test]
    fn a_refused_registration_is_never_announced_and_the_model_still_answers_him() {
        // **THE DEGRADATION, AND IT IS THE HALF THAT KEEPS THIS SAFE.** The app speaks only on
        // the register's own `recorded: true`; on anything else it says nothing at all and the
        // turn behaves exactly as it did before 2026-09-18 — the model says its line a round trip
        // later and he is answered. A host that spoke on the strength of the CALL having been
        // made would tell him "On it!" for work that was refused.
        let refused = r#"This conversation is not open for new assignments right now. Nothing was recorded."#;
        for (tag, receipt, error) in [
            ("register-refused", refused, true),
            ("register-refused-without-the-flag", refused, false),
            ("register-said-no", r#"{\"recorded\":false,\"say\":\"On it!\"}"#, false),
        ] {
            let log = a_handover_turn(tag, "toolu_R", receipt, error, "On it!");
            let said: Vec<&String> = log.iter().filter_map(|i| match i { TurnItem2::Said(t) => Some(t), _ => None }).collect();
            assert_eq!(said, vec!["On it!"], "{tag}: the model's own reply must still reach him: {log:#?}");
        }
    }

    #[test]
    fn only_the_register_s_own_result_is_read_and_only_on_its_own_id() {
        // A result that happens to carry the same two fields, on a DIFFERENT call, says nothing:
        // the id is what ties an answer to a question on this wire, and the app is speaking about
        // the register or it is not speaking.
        let receipt = r#"{\"recorded\":true,\"say\":\"Anyone can say this\"}"#;
        let log = a_handover_turn("the-registers-own-result", "toolu_R", receipt, false, "Done.");
        let said: Vec<String> = log.iter().filter_map(|i| match i { TurnItem2::Said(t) => Some(t.clone()), _ => None }).collect();
        // The app says what its OWN server handed back, whatever that is — the sentences are
        // `assignment::Receipt`'s and this host does not second-guess them. The model's "Done."
        // after it is withheld, which is the other half of the same rule.
        assert_eq!(said, vec!["Anyone can say this".to_string()], "{log:#?}");

        // The same frames with the result attributed to a call the register never made.
        let script = write_script("foreign-tool-result", r#"
read -r init
printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"req_init","response":{}}}'
read -r prompt
printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"toolu_BASH","name":"Bash","input":{}}}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_BASH","content":"{\"recorded\":true,\"say\":\"NOT RICH\"}"}]}}'
printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Done."}}}'
printf '%s\n' '{"type":"result","stop_reason":"end_turn"}'
"#);
        let client = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()).unwrap();
        let mut said = String::new();
        {
            let mut collect = |item: TurnItem| { if let TurnItem::Text { text, .. } = item { said.push_str(text) } };
            assert_eq!(client.prompt("Run the tests", &mut collect).unwrap(), "end_turn");
        }
        assert_eq!(said, "Done.", "a tool that is not the register must not be able to put words in his mouth");
    }

    #[test]
    fn the_receipt_is_a_fact_about_one_turn_and_the_next_turn_starts_again() {
        // The three fields reset with the SEND, like `spoken_this_turn` beside them. Without
        // this, turn 2's own reply would be withheld on the strength of turn 1's receipt — which
        // is a silent Rich, the worst failure this change could have.
        let script = write_script("receipt-resets-per-turn", r#"
read -r init
printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"req_init","response":{}}}'
read -r prompt
printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"toolu_R","name":"mcp__richos_assignments__record","input":{}}}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_R","content":"{\"recorded\":true,\"say\":\"On it!\"}"}]}}'
printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"On it!"}}}'
printf '%s\n' '{"type":"result","stop_reason":"end_turn"}'
read -r prompt
printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"It landed at four."}}}'
printf '%s\n' '{"type":"result","stop_reason":"end_turn"}'
"#);
        let client = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()).unwrap();
        for (prompt, expected) in [("Land the pricing branch", "On it!"), ("Did it land?", "It landed at four.")] {
            let mut said = String::new();
            let mut collect = |item: TurnItem| { if let TurnItem::Text { text, .. } = item { said.push_str(text) } };
            assert_eq!(client.prompt(prompt, &mut collect).unwrap(), "end_turn");
            assert_eq!(said, expected, "turn {prompt:?}");
        }
    }

    #[test]
    fn a_priming_turn_is_not_his_turn_and_nothing_is_said_on_it() {
        // The context-only turn carries no conversation at all (its text is discarded by the
        // spine), and the register cannot be called on it — `actions_allowed` is false for a
        // priming turn. The exclusion is asserted rather than assumed, because "the app now
        // speaks" must never mean "the app speaks on a turn he cannot see".
        let script = write_script("no-receipt-on-a-priming-turn", r#"
read -r init
printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"req_init","response":{}}}'
read -r prompt
printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","content_block":{"type":"tool_use","id":"toolu_R","name":"mcp__richos_assignments__record","input":{}}}}'
printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_R","content":"{\"recorded\":true,\"say\":\"On it!\"}"}]}}'
printf '%s\n' '{"type":"result","stop_reason":"end_turn"}'
"#);
        let mut client = NativeClient::spawn(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()).unwrap();
        let mut said = String::new();
        {
            let mut collect = |item: TurnItem| { if let TurnItem::Text { text, .. } = item { said.push_str(text) } };
            assert_eq!(client.prompt_context_only("[re-prime]", &mut collect).unwrap(), "end_turn");
        }
        assert_eq!(said, "", "a priming turn is not his turn: {said:?}");
    }

    #[test]
    fn the_pre_reply_gate_is_about_the_checkpoint_alone() {
        // The pure predicate, spelled out, because the scope is the whole decision: a WRITE
        // has nowhere to be before the reply, a READ may be the answer he is waiting for, and
        // the register is the one tool that is SUPPOSED to be called before he hears anything.
        let checkpoint = json!({"subtype":"can_use_tool","tool_name":CONTINUITY_CHECKPOINT_TOOL,"input":{}});
        assert!(bookkeeping_before_the_reply(&checkpoint, false));
        assert!(!bookkeeping_before_the_reply(&checkpoint, true));
        for tool in ["mcp__richos_continuity__inspect", crate::assignment_tools::QUALIFIED_RECORD_TOOL,
                     "mcp__richos_status__background_work", "Bash", ""] {
            let request = json!({"subtype":"can_use_tool","tool_name":tool,"input":{}});
            assert!(!bookkeeping_before_the_reply(&request, false), "{tool} must not be gated on the reply");
        }
        // A request with no tool name at all is not this gate's business — the desk below
        // already refuses it by name ("could not be safely displayed").
        assert!(!bookkeeping_before_the_reply(&json!({"subtype":"can_use_tool"}), false));
    }

    #[test]
    fn the_doctrine_and_the_gate_ask_for_the_same_order() {
        // **THE PAIR, TESTED AS A PAIR.** The gate above is the enforcement and this is the
        // instruction; a gate whose doctrine still said "as you go" would refuse the model for
        // doing what it was told, which is worse than either half alone. The doctrine is what
        // the conversation lease is actually given (`engine_profile.rs:158`).
        let doctrine = crate::doctrine::FRONT_DESK_DOCTRINE;
        // Wrap-safe: the doctrine is hard-wrapped prose, so every assertion stays inside one
        // line of it.
        assert!(doctrine.contains("**Write it after you have answered him, never before.**"),
            "the checkpoint's place in the turn is not stated");
        assert!(doctrine.contains("It is bookkeeping."), "the reason is not given, so the rule is arbitrary");
        // The refusal is announced, so a model that meets it knows it is the order and not a
        // permission it lacks.
        assert!(doctrine.contains("refused if you try it before you have spoken"),
            "the doctrine does not say the gate exists");
        // **AND THE REGRESSION THE PAIR ITSELF CAUSED.** Moving the checkpoint after the reply
        // made the model close its turn with a SECOND copy of the line it had already said, and
        // the CEO read `"On it!On it!"` (this probe's own first run, 2026-09-18). The
        // instruction against it lives in the same paragraph, and
        // `examples/first_reply_timing_e2e.rs` fails on it.
        assert!(doctrine.contains("**Say it once, and let the checkpoint be the last thing on the turn.**"),
            "nothing tells it to say its line once");
        // **AND THE PART THAT ACTUALLY STOPPED IT.** "Say it once" alone was measured NOT
        // WORKING (two identical runs of prose, 4.3 s and 17.0 s apart, run 2 of
        // `docs/verification/first-reply-2026-09-18.md`): a tool call made after the reply
        // forces the model to produce another assistant message, and it fills it with the line
        // it has just been handed. So a hand-over turn carries no checkpoint at all — the
        // register already wrote that turn down.
        assert!(doctrine.contains("carries no checkpoint at all"),
            "a hand-over turn is not fenced off from the checkpoint");
        // Negative: the clause that produced the measured defect is gone. "written as you go"
        // is what a model obeys by checkpointing first.
        assert!(!doctrine.contains("as you go with the continuity tools"), "the superseded clause survives");
        // And §55's own rule is untouched by this change.
        assert!(doctrine.contains("FIRST tool call"), "the register's ordering rule was lost");
        assert!(doctrine.len() > 500, "the doctrine did not load: {} bytes", doctrine.len());
    }

    #[test]
    fn worker_settlement_requires_readable_evidence_before_a_normal_turn_end() {
        use crate::cognition::Cognition;
        use std::collections::BTreeMap;
        for scenario in ["open", "damaged", "missing", "unreadable", "empty", "settled"] {
            let script = write_script("audit-unsettled", r#"
read -r init
printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"req_init","response":{}}}'
read -r prompt
printf '%s\n' '{"type":"result","stop_reason":"end_turn"}'
read -r keep_alive
"#);
            let mut cognition = NativeCognition::start(&script, Path::new("/tmp"), &doctrine_fixture(), &skills_fixture()).unwrap();
            let root = script.parent().unwrap().join("state");
            let folder = root.join("evidence").join(&cognition.session_id);
            std::fs::create_dir_all(&folder).unwrap();
            let mut log = serde_json::json!({"schema":1,"callback":{"session_id":cognition.session_id,"hook_event_name":"SubagentStart","agent_id":"still-running"}}).to_string()+"\n";
            match scenario {
                "damaged" => log.push_str("{\"schema\":"),
                "empty" => log.clear(),
                "settled" => log.push_str(&(serde_json::json!({"schema":1,"callback":{"session_id":cognition.session_id,"hook_event_name":"SubagentStop","agent_id":"still-running"}}).to_string()+"\n")),
                _ => {},
            }
            std::fs::write(folder.join(".lock"), "").unwrap();
            match scenario {
                "missing" => {},
                "unreadable" => std::fs::create_dir(folder.join("callbacks.jsonl")).unwrap(),
                _ => std::fs::write(folder.join("callbacks.jsonl"), log).unwrap(),
            }
            let state = crate::app_workers::status(&root, Some(&cognition.session_id));
            cognition.engine_profile = Some(crate::engine_profile::EngineProfile {
                engine: root.clone(), coordination: root.clone(), plugin: root.clone(), state: root.clone(),
                runtime: crate::runtime::EngineRuntime {root: root.clone(), python:"/usr/bin/python3".into(), node:"/usr/bin/false".into(), git:"/usr/bin/git".into(),versions:BTreeMap::new()},
                work_scope:None, permissions:Default::default()
            });
            let result = cognition.prompt("Synthetic audit turn", &mut |_| {});
            let provider_alive = cognition.client.child.try_wait().unwrap().is_none();
            println!("SETTLEMENT scenario={scenario}, liveness_unknown={}, unattributed={:?}, result={result:?}, provider_alive={provider_alive}", state.liveness_unknown,state.unattributed);
            if matches!(scenario, "empty" | "settled") { assert_eq!(result.unwrap(),"end_turn"); assert!(provider_alive); }
            else { assert!(result.is_err()); assert!(!provider_alive); }
        }
    }

    #[test]
    fn nested_worker_text_and_results_never_become_the_leads_conversation() {
        let script = write_script("nested-worker-output", r#"
read -r init
printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"req_init","response":{}}}'
read -r prompt
printf '%s\n' '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"message_start"}}'
printf '%s\n' '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Lead"}}}'
printf '%s\n' '{"type":"stream_event","parent_tool_use_id":"worker-call","event":{"type":"message_start"}}'
printf '%s\n' '{"type":"stream_event","parent_tool_use_id":"worker-call","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"WORKER STREAM"}}}'
printf '%s\n' '{"type":"assistant","parent_tool_use_id":"worker-call","message":{"content":[{"type":"text","text":"WORKER REPORT"}]}}'
printf '%s\n' '{"type":"result","parent_tool_use_id":"worker-call","stop_reason":"worker_end"}'
printf '%s\n' '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"Lead"}]}}'
printf '%s\n' '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"content_block_delta","delta":{"type":"text_delta","text":" done"}}}'
printf '%s\n' '{"type":"result","stop_reason":"end_turn"}'
read -r prompt
printf '%s\n' '{"type":"stream_event","parent_tool_use_id":null,"event":{"type":"message_start"}}'
printf '%s\n' '{"type":"stream_event","parent_tool_use_id":"worker-call","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"WORKER AGAIN"}}}'
printf '%s\n' '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"Lead fallback"}]}}'
printf '%s\n' '{"type":"result","stop_reason":"end_turn"}'
"#);
        let client=NativeClient::spawn(&script,Path::new("/tmp"),&doctrine_fixture(),&skills_fixture()).unwrap();
        let mut visible=String::new();let mut reports=Vec::new();
        let reason=client.prompt("First fictional turn", &mut |item|match item {
            TurnItem::Text{text,..}=>visible.push_str(text),
            TurnItem::Machinery(record)=>reports.push(record),
        }).unwrap();
        assert_eq!(reason,"end_turn");assert_eq!(visible,"Lead done");
        assert!(reports.iter().any(|r|r.title=="Worker report" && r.payload.as_ref().is_some_and(|p|p["parent_tool_use_id"]=="worker-call" && p["block"]["text"]=="WORKER REPORT")));
        let mut fallback=String::new();
        client.prompt("Second fictional turn", &mut |item|if let TurnItem::Text{text,..}=item{fallback.push_str(text)}).unwrap();
        assert_eq!(fallback,"Lead fallback");
    }

    // ---- the permission seam -----------------------------------------------------------

    #[test]
    fn the_permission_seam_allows_today_and_carries_the_agents_proposed_input() {
        // Verbatim request from `run9-rust-driven.jsonl:17`.
        let request = json!({
            "subtype":"can_use_tool","tool_name":"Write","display_name":"Write",
            "input":{"file_path":"/private/tmp/claude-501/rust-probe-out.txt","content":"RUSTOK"},
            "description":"/private/tmp/claude-501/rust-probe-out.txt",
            "decision_reason":"Path is outside allowed working directories",
            "decision_reason_type":"workingDir",
            "tool_use_id":"toolu_015USp34XWJGrGpgNY6TLvbV"});
        let decision = decide_permission(&request);
        assert_eq!(decision.behavior(), "allow", "ported behaviour: acp.rs:469-479 auto-approved");
        match decision {
            PermissionDecision::Allow { updated_input } => {
                assert_eq!(updated_input, request["input"], "the agent's own input, unrewritten");
            }
            other => panic!("expected Allow, got {other:?}"),
        }
    }

    #[test]
    fn the_permission_seam_exists_as_a_seam_and_can_answer_no() {
        // R2 governance is DEFERRED, not abandoned (ceo-decisions §1, §16). This asserts the
        // seam is real: a `Deny` is representable and carries a reason, so the day Rich asks
        // the CEO instead of allowing, only `decide_permission` changes.
        let deny = PermissionDecision::Deny { message: "the CEO declined".into() };
        assert_eq!(deny.behavior(), "deny");
    }

    // ---- the cancel mapping (spike caveat C1) -------------------------------------------

    #[test]
    fn an_aborted_turn_is_reported_as_a_cancel_on_terminal_reason_not_stop_reason() {
        // C1: this wire says `stop_reason: null` + `error_during_execution`, and ONLY
        // `terminal_reason` separates the CEO's stop from a genuine failure. Verbatim from
        // `run9-rust-driven.jsonl:65`.
        let aborted = json!({"subtype":"error_during_execution","stop_reason":Value::Null,
                             "is_error":true,"terminal_reason":"aborted_streaming"});
        assert_eq!(stop_reason_of(&aborted), STOP_REASON_CANCELLED);

        // A clean end — `run9-rust-driven.jsonl:30`.
        let clean = json!({"subtype":"success","stop_reason":"end_turn","terminal_reason":"completed"});
        assert_eq!(stop_reason_of(&clean), "end_turn");

        // A REAL failure must NOT be reported as the CEO's stop. This is the whole reason
        // the mapping keys on `terminal_reason` and not on `subtype`.
        let failed = json!({"subtype":"error_during_execution","stop_reason":Value::Null,
                            "is_error":true,"terminal_reason":"error"});
        assert_eq!(stop_reason_of(&failed), "error_during_execution");
        assert_ne!(stop_reason_of(&failed), STOP_REASON_CANCELLED);

        // And a frame with no name for how it ended is never called `end_turn`.
        assert_eq!(stop_reason_of(&json!({})), "unknown");
    }

    // ---- the derived watermark numerator -------------------------------------------------

    #[test]
    fn the_context_numerator_sums_all_three_input_sides() {
        // 2 + 25_737 + 3_603 = 29_342 — the first of the four monotonic numerators
        // `findings.md` §4 reports for run9, re-derived rather than trusted. `input_tokens`
        // alone would have said 2.
        let usage = json!({"input_tokens":2,"cache_creation_input_tokens":3603,
                           "cache_read_input_tokens":25737,"output_tokens":95});
        assert_eq!(tokens_in_context(&usage), Some(29_342));
        assert_eq!(usage["input_tokens"].as_u64(), Some(2), "and the naive read would have been 2");

        // The last of the four: 2 + 29_597 + 69 = 29_668, still monotonic against 29_342.
        let later = json!({"input_tokens":2,"cache_creation_input_tokens":69,
                           "cache_read_input_tokens":29597});
        assert_eq!(tokens_in_context(&later), Some(29_668));
        assert!(29_668 > 29_342);

        // A usage object with no input side says nothing about the context, and a zero would
        // be a false measurement.
        assert_eq!(tokens_in_context(&json!({"output_tokens":95})), None);
        assert_eq!(tokens_in_context(&json!({})), None);
    }

    // ---- the between-turn lane -----------------------------------------------------------

    fn init_frame(uuid: &str, model: &str) -> Value {
        json!({"type":"system","subtype":"init","model":model,"tools":["Bash"],
               "session_id":"sess","uuid":uuid})
    }

    #[test]
    fn the_last_value_slot_suppresses_an_identical_session_meta_repeat() {
        // The measured shape: `system/init` arrives once per turn and says the same thing
        // each time. §1.2 — "retaining every repeat is waste; retaining the last is enough
        // to reconstruct".
        let mut lane = BetweenTurn::default();
        lane.offer_frame(init_frame("u1", "claude-sonnet-5"));
        lane.offer_frame(init_frame("u2", "claude-sonnet-5"));
        lane.offer_frame(init_frame("u3", "claude-sonnet-5"));
        let drained = lane.drain("sess");
        assert_eq!(drained.len(), 1, "three repeats that differ only by uuid are one record");
        assert_eq!(lane.suppressed(), 2);
        assert_eq!(drained[0].turn_id, None, "§1.4 G4 — a between-turn record has no turn");
    }

    #[test]
    fn suppression_survives_the_per_frame_uuid_which_verbatim_comparison_would_not() {
        // THE deviation this lane needed: the frames are never byte-identical, so a slot
        // comparing them verbatim would suppress zero and look alive while doing nothing.
        let a = init_frame("acbe3949a0de", "claude-sonnet-5");
        let b = init_frame("43f5fdcdeeae", "claude-sonnet-5");
        assert_ne!(a, b, "the frames really are different bytes");
        let mut lane = BetweenTurn::default();
        lane.offer_frame(a);
        lane.offer_frame(b);
        assert_eq!(lane.suppressed(), 1);
        assert_eq!(lane.drain("sess").len(), 1);
    }

    #[test]
    fn a_changed_session_meta_value_is_kept_because_it_is_a_different_statement() {
        let mut lane = BetweenTurn::default();
        lane.offer_frame(init_frame("u1", "claude-sonnet-5"));
        lane.offer_frame(init_frame("u2", "claude-opus-5"));
        let drained = lane.drain("sess");
        assert_eq!(drained.len(), 2, "the second says something the first did not");
        assert_eq!(lane.suppressed(), 0);
        // 0 then 1 — the lane's own counter, assigned at DRAIN.
        assert_eq!(drained.iter().map(|r| r.seq).collect::<Vec<_>>(), vec![0, 1]);
    }

    #[test]
    fn the_lane_counter_continues_across_drains_rather_than_restarting() {
        let mut lane = BetweenTurn::default();
        lane.offer_frame(init_frame("u1", "claude-sonnet-5"));
        assert_eq!(lane.drain("sess")[0].seq, 0);
        lane.offer_frame(json!({"type":"system","subtype":"thinking_tokens","estimated_tokens":50}));
        assert_eq!(lane.drain("sess")[0].seq, 1, "a drain is not a reset");
    }

    #[test]
    fn a_user_text_frame_is_still_the_one_deliberate_drop() {
        let mut lane = BetweenTurn::default();
        lane.offer_frame(json!({"type":"user","message":{"role":"user","content":[
                                 {"type":"text","text":"[Request interrupted by user]"}]}}));
        assert!(lane.drain("sess").is_empty());
        // And it consumed no position: the NEXT record is still 0.
        lane.offer_frame(json!({"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}));
        assert_eq!(lane.drain("sess")[0].seq, 0);
    }

    #[test]
    fn an_overflow_is_a_marker_record_and_never_a_silent_forget() {
        let mut lane = BetweenTurn::default();
        // BETWEEN_TURN_MAX + 3 non-mergeable, non-meta frames. `system/thinking_tokens` is
        // not SessionMeta, so nothing is collapsed and the cap is what bites.
        for i in 0..(BETWEEN_TURN_MAX + 3) {
            lane.offer_frame(json!({"type":"system","subtype":"thinking_tokens","estimated_tokens":i}));
        }
        let drained = lane.drain("sess");
        // 256 kept + 1 marker = 257. Re-derived here rather than trusted: the cap refuses
        // the 257th onwards, so 259 offered - 256 kept = 3 dropped.
        assert_eq!(drained.len(), BETWEEN_TURN_MAX + 1);
        let marker = drained.last().unwrap();
        assert_eq!(marker.title, crate::machinery::BETWEEN_TURN_OVERFLOW);
        assert_eq!(marker.payload.as_ref().unwrap()["dropped"], 3);
        // Reported once, then reset — a second drain does not re-accuse.
        assert!(lane.drain("sess").is_empty());
    }

    #[test]
    fn between_turn_text_is_retained_as_machinery_and_never_as_a_chunk() {
        // In a turn this is the clean-output path and has no machinery record. Between turns
        // there is no turn to attach it to, so §1.4 G5 says retain rather than drop — and it
        // travels on the machinery family, never `StreamEvent::Chunk`.
        let mut lane = BetweenTurn::default();
        lane.offer_frame(json!({"type":"assistant","message":{"role":"assistant","content":[
                                 {"type":"text","text":"orphan"}]}}));
        let drained = lane.drain("sess");
        assert_eq!(drained.len(), 1);
        assert_eq!(drained[0].kind, crate::machinery::MachineryKind::Unknown);
        assert_eq!(drained[0].title, "assistant:text");
        assert_eq!(drained[0].summary.as_deref(), Some("orphan"));
    }

    #[test]
    fn a_permission_request_parked_between_turns_drains_as_a_permission_record() {
        let mut lane = BetweenTurn::default();
        lane.push(BetweenItem::Permission {
            request: json!({"subtype":"can_use_tool","tool_name":"Bash",
                            "description":"ls -la","tool_use_id":"toolu_Z"}),
            chosen: "allow".into(),
        });
        let drained = lane.drain("sess");
        assert_eq!(drained.len(), 1);
        assert_eq!(drained[0].kind, crate::machinery::MachineryKind::PermissionRequested);
        assert_eq!(drained[0].title, "ls -la");
        assert_eq!(drained[0].tool_call_id.as_deref(), Some("toolu_Z"));
    }
}
