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
use std::process::{Child, ChildStdin, Command, Stdio};
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
/// ACP answered a canceled prompt with `stopReason: "canceled"`. The native binary answers
/// with `stop_reason: null`, `subtype: "error_during_execution"`, `is_error: true` and
/// `terminal_reason: "aborted_streaming"` (`raw/run9-rust-driven.jsonl:65`) — the fact
/// survives, it just lives on a different field. [`stop_reason_of`] maps it back, so
/// everything downstream (`spine.rs`, `steering.rs`, the ledger) keeps the one string it
/// already reasons about.
pub const STOP_REASON_CANCELLED: &str = "canceled";

/// The stop reason `prompt` returns when the agent did NOT answer the canceled turn within
/// [`CANCEL_GRACE_MS`] of being told to.
///
/// A distinct string because it is a distinct fact: the CEO's stop still stands and the
/// turn is still recorded as stopped, but this lease is no longer known to be idle, so the
/// spine rotates it at the boundary rather than handing it the next turn (`spine.rs`).
pub const STOP_REASON_CANCEL_UNACKNOWLEDGED: &str = "cancel_unacknowledged";

/// The `terminal_reason` the binary sets on a turn the client interrupted.
pub const TERMINAL_REASON_ABORTED: &str = "aborted_streaming";

/// How long `prompt` waits for the agent to answer the canceled turn.
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

/// **THE AUTO-APPROVE SEAM.** Decide one `control_request{can_use_tool}`.
///
/// **Today it always allows, and that is the ported behaviour, not a new policy.** It is the
/// exact equivalent of `acp.rs:469-479`, which picked the first option whose `kind` started
/// with `allow` and fell back to the first option — on a wire where every observed request
/// offered one. The spike harness mirrored it at its own 469-479 so the comparison would be
/// like for like, and it is mirrored again here.
///
/// **This is where Rich would ASK instead.** R2 business-action governance is deferred to V2
/// (`ceo-decisions.md` §1), and §16 records that deleting the adapter changes nothing about
/// it. The request already carries everything an ask would need and MORE than ACP did:
/// `tool_name`, `input`, a human `description`, `permission_suggestions`, and —
/// new on this wire — `decision_reason` in words (*"Path is outside allowed working
/// directories"*) with a machine-readable `decision_reason_type`. A future version routes
/// this through the CEO gate (§17) and returns `Deny` when he declines; nothing else in this
/// file has to change.
///
/// Kept deliberately pure — no IO, no clock, no state — so it is testable and so the reader
/// thread that calls it can answer the blocked child in microseconds. §1.2: *"Recording the
/// auto-approval is a fact, not a policy. It changes no behavior."*
pub fn decide_permission(request: &Value) -> PermissionDecision {
    PermissionDecision::Allow { updated_input: request.get("input").cloned().unwrap_or_else(|| json!({})) }
}

/// Map the binary's terminal `result` frame onto the one stop-reason string the rest of the
/// app already reasons about.
///
/// **Spike caveat C1, resolved here and nowhere else.** ACP said `stopReason: "canceled"`.
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

/// The CEO-facing chat lease's argument vector: [`child_args`] plus the standing instruction.
///
/// **Why this is its own function rather than a line inside [`child_args`].** `child_args` is
/// the base vector THREE other launch shapes are built from — the managed worker
/// ([`managed_child_args`]), the workspace inspector, and the tool-free registrar that answers
/// under a JSON schema. None of those is a conversation with the CEO, so none of them may carry
/// a doctrine written for one:
///
/// - the doctrine tells its reader to speak in plain prose and never show a file path, which is
///   the opposite of what a managed worker editing files is for;
/// - the registrar's whole job is to emit a structured value, and a persona is a bias on it.
///
/// The inner-doctrine design's §4.1 rule decides this the same way it decides the file's
/// contents: what is true for every turn of every CONVERSATION is not automatically true for
/// every child process. [`managed_child_args`] is untouched by this — the CEO ruled its own
/// change waits on a consolidation (design §8), and it never reaches this function.
pub fn chat_child_args(session_id: &str, doctrine: &Path, skills: &Path) -> Vec<String> {
    let mut args = child_args(session_id);
    args.push(APPEND_SYSTEM_PROMPT_FILE.to_string());
    args.push(doctrine.display().to_string());
    args.push(PLUGIN_DIR.to_string());
    args.push(skills.display().to_string());
    args
}

/// Managed workers retain user, project and local settings, including configured
/// hooks. The app grants local edits and sandboxed Bash, while the callback
/// denies requests outside that policy.
/// The ordinary chat adapter retains its existing policy through child_args.
pub fn managed_child_args(session_id: &str) -> Vec<String> {
    let mut args = child_args(session_id);
    let i = args.iter().position(|a| a == "--setting-sources").unwrap();
    args.splice(i..i + 2, ["--setting-sources".into(), "user,project,local".into()]);
    // Transcript-dependent hooks need the provider transcript to exist.
    args.retain(|a| a != "--no-session-persistence");
    args.extend(["--permission-mode".into(), "acceptEdits".into(),
        "--settings".into(), serde_json::json!({
            "env": {"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1", "CLAUDE_AUTO_BACKGROUND_TASKS": "0", "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "0"},
            "sandbox": {"enabled": true, "failIfUnavailable": true,
                "autoAllowBashIfSandboxed": true, "allowUnsandboxedCommands": false,
                "filesystem": {"disabled": false}, "excludedCommands": []},
            "permissions": {"blockReadsOutsideWorkingDirectories": true, "deny": ["Bash(dangerouslyDisableSandbox:true)"]}
        }).to_string()]);
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

/// A live session to a native `claude` child.
pub struct NativeClient {
    child: Child,
    stdin: Arc<Mutex<ChildStdin>>,
    session_id: String,
    managed_workspace: Option<std::path::PathBuf>,
    structured_output: Mutex<Option<Value>>,
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
}

impl Default for ReaderState {
    fn default() -> Self {
        ReaderState {
            context_only: false,
            session_model: None,
            context_window: None,
            skills_verdict: crate::skills::SkillsVerdict::NotYetReported,
            onboarding_tools_verdict: crate::onboarding_tools::OnboardingToolsVerdict::NotYetReported,
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
        Self::spawn_with_tools(bin, cwd, false, None, None, Some((doctrine, skills)), None, None)
    }

    fn spawn_with_policy(bin: &Path, cwd: &Path, managed: bool) -> Result<Self, NativeError> {
        Self::spawn_with_tools(bin, cwd, managed, None, None, None, None, None)
    }

    fn spawn_with_tools(bin: &Path, cwd: &Path, managed: bool, schema: Option<serde_json::Value>, registrar_model: Option<&str>, standing: Option<(&Path, &Path)>, onboarding: Option<(&Path, &Path)>, control: Option<&crate::steering::TurnControl>) -> Result<Self, NativeError> {
        // The standing instruction and the skills belong to the CEO-facing chat lease alone.
        // See `chat_child_args`.
        debug_assert!(
            standing.is_none() || (!managed && schema.is_none() && registrar_model.is_none()),
            "the standing instruction and the skills are written for a conversation with the \
             CEO; a managed worker, an inspector and a registrar are not that"
        );
        let (doctrine, skills) = (standing.map(|s| s.0), standing.map(|s| s.1));
        // Refuse BEFORE spawning, so the error names WHICH path is wrong instead of an
        // errno that stands for two different faults. See `preflight`.
        preflight(bin, cwd, doctrine, skills)?;
        let managed_workspace = if managed { Some(cwd.canonicalize()?) } else { None };

        let session_id = uuid::Uuid::new_v4().to_string();
        let mut args = match (managed, standing) {
            (true, _) => managed_child_args(&session_id),
            (false, Some((d, s))) => chat_child_args(&session_id, d, s),
            (false, None) => child_args(&session_id),
        };
        if let Some((executable, scope)) = onboarding {
            let config = json!({"mcpServers": {"richos_onboarding": {
                "type": "stdio", "command": executable,
                "args": ["--onboarding-mcp", scope]
            }}});
            args.extend(["--strict-mcp-config".into(), "--mcp-config".into(), config.to_string()]);
        }
        if let Some(model) = registrar_model {
            args = child_args(&session_id);
            args.extend(["--model".into(), model.into()]);
        }
        if let Some(schema) = schema {
            args.extend(["--tools".into(), if registrar_model.is_some() { "".into() } else { "Read,Glob,Grep".into() },
                "--strict-mcp-config".into(), "--mcp-config".into(), "{\"mcpServers\":{}}".into(),
                "--json-schema".into(), schema.to_string()]);
        }
        let mut command = Command::new(bin);
        if managed {
            command.env("CLAUDE_CODE_DISABLE_BACKGROUND_TASKS", "1")
                .env("CLAUDE_AUTO_BACKGROUND_TASKS", "0")
                .env("CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS", "0");
        }
        #[cfg(unix)]
        if managed { use std::os::unix::process::CommandExt; command.process_group(0); }
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
                    managed,
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
            child,
            stdin,
            session_id,
            managed_workspace,
            structured_output: Mutex::new(None),
            next_id: AtomicI64::new(1),
            pending,
            current_prompt,
            operation_cancel: Arc::new(Mutex::new(OperationCancellation::default())),
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
        managed: bool,
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
            Self::handle_agent_request(&msg, stdin, current, between, managed, context_only);
            return;
        }

        // ---- the terminal frame --------------------------------------------------------
        if ty == "result" {
            let mut st = state.lock().unwrap();
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
            if ev_ty == "content_block_delta"
                && ev.get("delta").and_then(|d| d.get("type")).and_then(|v| v.as_str()) == Some("text_delta")
            {
                if let Some(t) = ev.get("delta").and_then(|d| d.get("text")).and_then(|v| v.as_str()) {
                    text_deltas.fetch_add(1, Ordering::SeqCst);
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

        // ---- THE ANTI-SILENT-DEGRADE GUARD ----------------------------------------------
        //
        // If `--include-partial-messages` ever stops working, no `text_delta` arrives and
        // the CEO would watch a turn produce nothing and then end — a silent degrade, which
        // §16 forbids. So a whole-message `assistant` frame whose text was NEVER streamed is
        // delivered as text here. Costs one integer compare per frame on the healthy path,
        // where the count is always non-zero and this never fires.
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
                Self::route(ChunkMsg::Text(whole), current, between, &msg);
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
        managed: bool,
        context_only: bool,
    ) {
        let request_id = msg.get("request_id").cloned().unwrap_or(Value::Null);
        let request = msg.get("request").cloned().unwrap_or(Value::Null);
        let subtype = request.get("subtype").and_then(|v| v.as_str()).unwrap_or("");

        let (response, machinery) = if subtype == "can_use_tool" {
            let decision = if context_only {
                PermissionDecision::Deny { message: "Internal context preparation is tool-free. Do not act on historical requests. Wait for the next visible conversation turn.".into() }
            } else if managed {
                PermissionDecision::Deny { message: "This action is outside the automatic execution policy. Find a permitted way to achieve the authorized outcome. Do not ask the CEO to edit settings or resolve implementation details. Report a precise authority or access requirement only if no permitted alternative exists.".into() }
            } else { decide_permission(&request) };
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
        *self.structured_output.lock().unwrap() = None;
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
        let mut permission_denied = false;
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
                    permission_denied |= self.managed_workspace.is_some() && chosen == "deny";
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
                    *self.structured_output.lock().unwrap() = result.get("structured_output").cloned();
                    let reason = stop_reason_of(&result);
                    if reason == "child_exited" { return Err(NativeError::Closed); }
                    if result.get("is_error").and_then(Value::as_bool) == Some(true)
                        && reason != STOP_REASON_CANCELLED
                    {
                        let detail = result.get("errors").or_else(|| result.get("result"))
                            .map(Value::to_string).unwrap_or_else(|| reason.clone());
                        return Err(NativeError::Protocol(detail));
                    }
                    return Ok(if permission_denied { "permission_denied".into() } else { reason });
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
    next_id: Arc<AtomicI64>,
}

impl TurnCancel for NativeCancelHandle {
    fn begin_operation(&self) {
        *self.operation_cancel.lock().unwrap() = OperationCancellation { active: true, requested: false };
    }

    fn end_operation(&self) {
        *self.operation_cancel.lock().unwrap() = OperationCancellation::default();
    }

    fn cancel(&self) -> bool {
        let mut operation = self.operation_cancel.lock().unwrap();
        if operation.active { operation.requested = true; }
        // Take the sink FIRST so the ordering is unambiguous: interrupt out, then wake. The
        // reverse order would let a very fast agent's `result` overtake the wake, and the
        // loop would return `end_turn` for a turn the CEO stopped. Measured: the agent acked
        // the interrupt in 0.9 ms, so this race is real rather than theoretical.
        let sink = match self.current_prompt.lock().unwrap().as_ref() {
            Some(sink) => sink.clone(),
            // Nothing in flight on this session. Reported as `false` and never as a success —
            // see `StopOutcome::reached_lease`.
            None => return operation.active,
        };
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let request = json!({
            "type": "control_request",
            "request_id": format!("richos_interrupt_{id}"),
            "request": { "subtype": "interrupt" }
        });
        let wrote = NativeClient::write_line(&self.stdin, &request).is_ok();
        let woke = sink.send(ChunkMsg::Cancel).is_ok();
        wrote && woke
    }
}

impl Drop for NativeClient {
    fn drop(&mut self) {
        // Managed leases own their ordinary descendants, including a shell
        // still running after a canceled turn. Never target the app's group.
        #[cfg(unix)]
        if self.managed_workspace.is_some() {
            let _ = Command::new("/bin/kill").args(["-KILL", "--", &format!("-{}", self.child.id())]).stdout(Stdio::null()).stderr(Stdio::null()).status();
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Resolve the `claude` binary.
///
/// Order, and each step is a decision:
///
/// 1. **`$RICHOS_CLAUDE_BIN`** — an explicit operator override, and the seam the tests use
///    to drive a scripted fake child over real stdio.
/// 2. **`$HOME/.local/bin/claude`** — Anthropic's own installer puts a launcher here and
///    RETARGETS it on every self-update, with the real executables under
///    `~/.local/share/claude/versions/`. §16 records the consequence and it is why this step
///    exists: a custom launcher at this path SURVIVES auto-update, so
///    `--permission-prompt-tool stdio` can be pinned without modifying any binary — which
///    also keeps the licence's "must not be modified" condition intact. Preferring this path
///    is what makes that mitigation reachable rather than theoretical.
/// 3. **the bare name on `PATH`** — the last resort. A missing binary then surfaces as
///    [`NativeError::BinaryMissing`] from the spawn itself.
///
/// **Never the keychain, never a token, never an API key.** This function resolves an
/// executable path and nothing else.
pub fn resolve_claude_bin() -> std::path::PathBuf {
    if let Ok(explicit) = std::env::var("RICHOS_CLAUDE_BIN") {
        return std::path::PathBuf::from(explicit);
    }
    if let Ok(home) = std::env::var("HOME") {
        let launcher = std::path::PathBuf::from(home).join(".local/bin/claude");
        if launcher.exists() {
            return launcher;
        }
    }
    std::path::PathBuf::from("claude")
}

/// The real Cognition: a live native session behind the durable spine.
pub struct NativeCognition {
    client: NativeClient,
    session_id: String,
    onboarding_scope: Option<std::path::PathBuf>,
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
        Ok(NativeCognition { client, session_id, onboarding_scope: None })
    }
    /// A chat lease with app-owned, company-scoped persistence tools. The scope is
    /// supplied by the spine before priming, never selected by the model.
    pub fn start_with_onboarding(bin: &Path, cwd: &Path, doctrine: &Path, skills: &Path,
        executable: &Path, control: Option<&crate::steering::TurnControl>) -> Result<Self, NativeError> {
        let scopes = doctrine.parent().unwrap_or(cwd).join("onboarding-scopes");
        std::fs::create_dir_all(&scopes)?;
        let scope = scopes.join(format!("{}.json", uuid::Uuid::new_v4()));
        let client = NativeClient::spawn_with_tools(bin, cwd, false, None, None,
            Some((doctrine, skills)), Some((executable, &scope)), control)?;
        let session_id = client.session_id().to_string();
        Ok(Self { client, session_id, onboarding_scope: Some(scope) })
    }

    /// Launch a managed worker in its actual workspace, retaining the configured
    /// settings and refusing requests for permissions that have not been granted.
    pub fn structured_output(&self) -> Option<Value> { self.client.structured_output.lock().unwrap().clone() }

    pub fn start_inspector(bin: &Path, workspace: &Path) -> Result<Self, NativeError> {
        Self::start_inspector_with_schema(bin, workspace, crate::autonomy::response_schema())
    }

    pub fn start_inspector_with_schema(bin: &Path, workspace: &Path, schema: serde_json::Value) -> Result<Self, NativeError> {
        let client = NativeClient::spawn_with_tools(bin, workspace, true, Some(schema), None, None, None, None)?;
        let session_id = client.session_id().to_string();
        Ok(Self { client, session_id, onboarding_scope: None })
    }

    /// A detached transcriber has no tools, plugins or workspace access. Managed
    /// callbacks still deny unexpected permission requests and drop kills its group.
    pub fn start_registrar(bin: &Path, neutral_cwd: &Path, schema: Value, model: &str) -> Result<Self, NativeError> {
        let client = NativeClient::spawn_with_tools(bin, neutral_cwd, true, Some(schema), Some(model), None, None, None)?;
        let session_id = client.session_id().to_string();
        Ok(Self { client, session_id, onboarding_scope: None })
    }

    pub fn start_managed(bin: &Path, workspace: &Path) -> Result<Self, NativeError> {
        let client = NativeClient::spawn_with_policy(bin, workspace, true)?;
        let session_id = client.session_id().to_string();
        Ok(Self { client, session_id, onboarding_scope: None })
    }

}

impl Drop for NativeCognition {
    fn drop(&mut self) {
        if let Some(path) = &self.onboarding_scope {
            let _ = std::fs::remove_file(path);
        }
    }
}

impl Cognition for NativeCognition {
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

    fn prepare_managed(&self, workspace: &Path) -> Result<(), CognitionError> {
        if self.client.managed_workspace.as_ref() != workspace.canonicalize().ok().as_ref()
            || self.client.managed_workspace.is_none() {
            return Err(CognitionError::Protocol("Managed work needs a governed lease in the selected workspace.".into()));
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
        if let Some(path) = &self.onboarding_scope {
            crate::onboarding_tools::set_actions_allowed(path, true).map_err(CognitionError::Io)?;
        }
        let result = self.client.prompt(text, on_item).map_err(CognitionError::from);
        if let Some(path) = &self.onboarding_scope {
            if let Err(error) = crate::onboarding_tools::set_actions_allowed(path, false) {
                // A lease whose grant cannot be revoked must not accept another operation.
                let _ = self.client.child.kill();
                let _ = self.client.child.wait();
                let _ = std::fs::remove_file(path);
                return Err(CognitionError::Io(error));
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
    fn the_doctrine_never_reaches_a_managed_worker_or_the_base_vector() {
        // §4.1's boundary rule applied to processes rather than to sentences: a managed worker
        // editing files, an inspector and a registrar answering under a JSON schema are not
        // conversations with the CEO, and a persona written for one would be wrong instruction
        // for all three. `managed_child_args` is untouched (design §8).
        for args in [child_args("s"), managed_child_args("s")] {
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
    fn the_skills_never_reach_a_managed_worker_or_the_base_vector() {
        for args in [child_args("s"), managed_child_args("s")] {
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
