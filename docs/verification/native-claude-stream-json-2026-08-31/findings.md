# Can RichOS delete its last npm dependency?

> **Path note (2026-09-01).** The ACP adapter this record measures — app/acp-adapter/ and app/crates/richos-core/src/acp.rs — was deleted in a45acc3. Filenames below are therefore given bare: they resolve in git history at that commit, not in the current tree.

**Spike, 2026-08-31. Verdict: YES, WITH FOUR NAMED CAVEATS — none of them blocking, one of
them a decision that belongs to the CEO rather than to me.**

Every capability `acp.rs` actually consumes today has an
**observed** equivalent on the native `claude` binary's stream-json stdio, driven from Rust.
Two of them arrive in a poorer form and RichOS would have to do work the adapter does for it
now; one moves to a different field; one is a new fragility. The port is real work and it is
not this brief. This document is the evidence and the verdict, nothing more.

---

## 1. What was measured

**The agent under test.** `/Users/alex/.local/share/claude/versions/2.1.251` —
Mach-O 64-bit executable arm64, **197,171,680 bytes (188.0 MiB)**. `otool -L` lists four
linked libraries and all four are system: `libicucore.A.dylib`, `libresolv.9.dylib`,
`libc++.1.dylib`, `libSystem.B.dylib`. **No Node runtime is linked, and none is bundled.**
`/Users/alex/.local/bin/claude` is a symlink to it.

**Twelve runs**, raw output committed unedited under `raw/`, indexed by `raw/README.md`.
Run 9 is the definitive one: **all four legs from Rust, in one process**, driven by
`tools/native-claude-stdio`, which is deliberately shaped like `acp.rs` (spawn → one reader
thread → dispatch → per-turn mpsc, same first-`allow*` auto-approve policy as
`acp.rs:469-479`) because "does the structure port" is half of what is being asked.

**Every run had `ANTHROPIC_API_KEY` removed from the environment** (`env -u`). The auth
question is one of the four, and an inherited key would have answered it wrong and quietly.

**The comparison is against evidence, not against my reading of the code.** The ACP column
below is grounded in the 2026-08-28 emission probe
(`docs/verification/acp-emission-probe-2026-08-28/observed-kinds.json`, five runs against
adapter 0.70.0), not in what `acp.rs` looks like it expects.

---

## 2. The dependency that would go away is not one package

The adapter's `package.json` declares exactly one dependency,
`@agentclientprotocol/claude-agent-acp: "^0.70.0"`. That is the shipped npm surface as
*declared*. As *resolved*, its `package-lock.json` pins:

| | count |
|---|---|
| packages in the resolved tree | **112** |
| Anthropic / ACP first-party (`@anthropic-ai/*`, `@agentclientprotocol/*`) | 12 |
| **third-party packages, from ~90 distinct publishers** | **100** |

The third-party 100 include a complete Express HTTP server stack (`express`, `body-parser`,
`cors`, `send`, `serve-static`, `router`, `proxy-addr`, `qs`, `raw-body`, `finalhandler`,
`express-rate-limit`), a second HTTP server (`hono`, `@hono/node-server`), a JOSE
implementation (`jose`), crypto (`@stablelib/base64`, `fast-sha256`, `pkce-challenge`), and
`cross-spawn`.

This is the fact that makes the CEO's concern precise rather than general. **The caret in
`^0.70.0` means a fresh `npm install` accepts any 0.70.x published after the lockfile was
written**, and each of ~90 publishers is a place a compromise can enter a bundle that is
then signed with his own Developer ID. Signing does not check any of this; it attests that
*he* shipped it.

Deleting the adapter also deletes the bundled Node runtime it needs — a packaging
consequence, not measured here, and worth its own number before anyone claims a size win.

---

## 3. The auth answer — OBSERVED, and it is the good one

**The native path needs no `ANTHROPIC_API_KEY`. It uses the same subscription OAuth the ACP
adapter uses today. This is not a product change.**

With `ANTHROPIC_API_KEY` removed from the environment, the binary reported, unprompted:

- `system/init` → `"apiKeySource": "none"` (`raw/run3-tool-permission-manual.jsonl:1`)
- control `initialize` → `"account": {"email": "abbooster@gmail.com", "organization":
  "abbooster@gmail.com's Organization", "subscriptionType": "Claude Max", "apiProvider":
  "firstParty"}` (`raw/run9-rust-driven.jsonl`, the `req_init` response)

and then completed every run of real turns below. `acp.rs`'s header claim — *"Auth = the
developer's `claude` CLI keychain OAuth; no ANTHROPIC_API_KEY needed"* (`acp.rs:13`) — holds
identically on the native path.

One corroborating detail from `claude --help`, and it is **inference from documentation, not
observation**: the `--bare` flag documents itself as the mode in which "Anthropic auth is
strictly ANTHROPIC_API_KEY or apiKeyHelper … OAuth and keychain are never read". We do not
pass `--bare`, and the observations above are what actually happened.

---

## 4. Side by side — what `acp.rs` consumes, and whether stream-json provides it

Every row is marked from a captured artifact. **`OBSERVED` means I have the bytes.
`NOT OBSERVED` means exactly that and nothing stronger** — it is not a claim the capability
is absent.

| What `acp.rs` consumes today | ACP (measured 2026-08-28) | Native stream-json | Evidence |
|---|---|---|---|
| **Streamed assistant text** | `session/update` → `agent_message_chunk` → `content.text` (`acp.rs:379-384`) | **OBSERVED.** `stream_event` → `content_block_delta` → `text_delta`, plus a whole-message `assistant` event | `raw/run1:6-7`; `run9` |
| **Turn completion + stop reason** | response to `session/prompt`, `{stopReason, usage}` (`acp.rs:669`) | **OBSERVED.** `result` with `stop_reason: "end_turn"`, `subtype: "success"`, `terminal_reason: "completed"` | `run9:31,42,76` |
| **Session continuity across turns** | one adapter process, `sessionId` from `session/new` | **OBSERVED.** One long-lived process, one `session_id`; turn 2 recalled `5309` from turn 1 | `run9:42`; independently `run2` (`4271`) |
| **Session `cwd` = the engine repo** (loads persona/hooks) | `session/new {cwd}` (`acp.rs:544`) | **OBSERVED.** The child's process `cwd`, echoed back in `system/init.cwd` | `run3:1` |
| **Tool calls** | `tool_call` / `tool_call_update` | **OBSERVED.** `assistant` → `tool_use` with `id`, `name`, `input` | `run3:13`; `run11` |
| **The real tool name** | buried in `_meta.claudeCode.toolName`; the ACP `kind` is a coarse class (`machinery.rs:511-515`) | **OBSERVED, and better.** `tool_use.name` is `"Bash"` / `"Write"` / `"Edit"` directly — no `_meta` indirection | `run3:13`, `run11` |
| **Tool status / outcome** | `status` field, `pending` → `in_progress` → `completed` (`machinery.rs:277`) | **OBSERVED as a PAIR, not a status string.** `tool_use` then `tool_result` with `is_error: false\|true`. **No intermediate in-progress event was observed.** See caveat C2 — **now CLOSED: an intermediate `tool_progress` frame IS emitted on a 30 s cadence, `../native-claude-tool-status-2026-08-31/`** | `run3:13,17` |
| **Tool argument streaming** | not observed in the ACP probe | **OBSERVED.** `input_json_delta` streams tool arguments as they are generated | `run3:6-12` |
| **Permission requests** | `session/request_permission`, auto-approved first `allow*` (`acp.rs:469-479`); 7 observed across 5 runs | **OBSERVED, end to end, and richer.** `control_request{can_use_tool}` carrying `tool_name`, `input`, `description`, `permission_suggestions`, **`decision_reason`** ("Path is outside allowed working directories") and `decision_reason_type`. Our `allow` was honoured — the file appeared on disk | `run8`; `run9` (`can_use_tool Write → ALLOW`, file contained `RUSTOK`); `run11` (Edit) |
| **Cancellation** | `session/cancel` notification; `stopReason: "cancelled"` (`acp.rs:716`, `STOP_REASON_CANCELLED`) | **OBSERVED, on a different field.** `control_request{interrupt}` → **acked in 0.9 ms**, result at **9.1 ms**. `stop_reason` is `null` and `subtype` is `error_during_execution`, but **`terminal_reason: "aborted_streaming"`** distinguishes it from `"completed"`. Partial text is preserved and an explicit `[Request interrupted by user]` marker is injected. See caveat C1 | `run9:65,66`; `run5` |
| **Lease survives a cancel** | assumed by the spine (rotation is a boundary decision, not a cancel consequence) | **OBSERVED.** Process alive after interrupt; the very next turn returned `REUSE-OK` with the session's context intact | `run9`, `PROCESS ALIVE AFTER INTERRUPT: true`; independently `run6` (`8813` recalled) |
| **Context watermark `{used, size}`** for proactive rotation (§3.2; `machinery.rs:305`) | `usage_update` with `used`/`size` directly; 6–26 per turn | **OBSERVED, but DERIVED not given.** `used` = `message_delta.usage` (`input_tokens` + `cache_read_input_tokens` + `cache_creation_input_tokens`), mid-turn, monotonic: 29,342 → 29,528 → 29,599 → 30,113. `size` = `result.modelUsage["claude-sonnet-5"].contextWindow` = **1,000,000**. See caveat C3 | `run9:20,29,40,74` and `run9:31` |
| **Usage / cost** | `usage` on the prompt response | **OBSERVED, and far richer.** `result.usage` (incl. cache split, `service_tier`, per-iteration), `modelUsage` per model with `contextWindow` and `costUSD`, `total_cost_usd`, `ttft_ms`, `duration_api_ms` | `run3` result, full inventory |
| **Thinking** | `agent_thought_chunk` → `machinery.rs:254`. **NOT OBSERVED in 5 ACP runs**, including a run that explicitly demanded hard reasoning | **OBSERVED as presence only.** 7 `thinking` content blocks across the native captures, **all with empty `thinking` text** (signature only), plus `system/thinking_tokens` estimates. **Neither path delivered readable thinking text.** No regression either way | `run9`, `run11`; ACP: `observed-kinds.json` → `tableKindsNotObserved` |
| **Session meta** (`available_commands_update`, `session_info_update`) | last-value-wins family, exactly one of each per turn (`machinery.rs:75-90`) | **OBSERVED, and richer.** `system/init` per turn carries `slash_commands` (49), `agents`, `models`, `tools`, `mcp_servers`, `permissionMode`, `capabilities` | `run3:1`; `run9` |
| **`plan`** | `plan` updates observed (15 in one ACP run, from TodoWrite) | **NOT OBSERVED — and the reason is known.** `TodoWrite` is not in this build's tool list, so the run that asked for it could not produce one. This row is genuinely open | `run11` (agent replied "TodoWrite isn't available") |
| **`fs/read_text_file` / `fs/write_text_file`** — client-directed file IO (`acp.rs:481-487`) | **NOT OBSERVED in 5 ACP runs** either (`tableMethodsNotObserved`) | **OBSERVED NOT TO HAPPEN.** The CLI does its own file IO: it wrote `rust-probe-out.txt` and edited `edit-target.txt` itself, asking us only for *permission*, never to perform the read or write | `run9`, `run11` |

---

## 5. What stream-json gives that ACP does not

All observed.

- **`set_model` mid-session**, no restart: `control_request{set_model: "opus"}` →
  `success` (`raw/run10:2`). `acp.rs` has no equivalent.
- **`decision_reason` on a permission request** — *why* approval is needed, in words
  ("Path is outside allowed working directories"), with a `decision_reason_type`.
- **A structured error for an unsupported control request** rather than silence:
  `"Unsupported control request subtype: no_such_subtype_at_all"` (`raw/run10:3`). This is a
  **positive** protocol-error signal, which is what §5.2's watchdog requires.
- **Streamed tool arguments** (`input_json_delta`) as the agent composes them.
- **`still_queued`** on the interrupt response and `queued_turn_count` on the result — the
  agent's own view of the queue, which the turn-boundary state machine currently has to
  infer.
- **`permission_denials`** enumerated on every result.
- **Far more usage detail**, including `contextWindow` per model and real cost.

## 6. What ACP gives that stream-json does not

Both observed; both are rendering losses, not capability losses.

- **A pre-rendered diff.** ACP's `session/request_permission` embeds
  `content: [{type: "diff", path, oldText, newText}]` and a `locations` array
  (`observed-kinds.json`, run1 n=33). The native `can_use_tool` for `Edit` carries the
  *intent* — `{file_path, old_string, new_string, replace_all}` — and no `locations`
  (`raw/run11`). **RichOS would have to read the file and compute the diff itself** to render
  what `machinery.rs`'s `extract_locations` and the techy view show today.
- **A resolved human title.** ACP supplies `toolCall.title` ("Write /tmp/…", the full shell
  command). Native supplies `input.description` on some tools ("Echo test string") and
  otherwise raw input. `machinery.rs:231-252`'s careful title/merge logic — including the
  measured `run1 n=15` case where falling back to `_meta` would have overwritten a good title
  with the word "Bash" — is written against the ACP shape and would need re-deriving.

---

## 7. The four caveats

**C1 — Cancellation moves from `stop_reason` to `terminal_reason`.** ACP answers a cancelled
prompt with `stopReason: "cancelled"`, which is what `STOP_REASON_CANCELLED` and the whole
`CANCEL_GRACE_MS` / `STOP_REASON_CANCEL_UNACKNOWLEDGED` design in `acp.rs:29-51` hang off.
Native reports `stop_reason: null` + `subtype: "error_during_execution"` + `is_error: true`,
and only `terminal_reason: "aborted_streaming"` separates a cancel from a genuine error. The
distinction survives; it lives somewhere else. **And the grace-window design gets its first
real number**: `acp.rs:49` says of `CANCEL_GRACE_MS = 3_000` that it "has not been measured
against a live adapter" and asks whoever runs the first live stop to replace it with a
measured figure. Measured here, native path: **ack 0.9 ms, terminal result 9.1 ms**
(`run9`); the Python driver independently measured 10 ms / 20 ms (`run5`). Against a 3,000 ms
bound that is **three orders of magnitude of headroom** — 3000 ÷ 9.1 ≈ 330×. This is the
native path's number, not the adapter's, and it does not retire the comment in `acp.rs`.

**C2 — No intermediate tool status was observed.** ACP emits `tool_call_update` with
`status` transitions (20 of them in one measured run). Native emits `tool_use` then
`tool_result`. For a long-running tool the techy view would show "started" and then
"finished" with nothing between. I did not run a long-enough tool to prove there is nothing
in between, so this is **NOT OBSERVED, not "absent"** — it needs one deliberate long-tool run
before anyone sizes the port.

> **CLOSED 2026-08-31 by `../native-claude-tool-status-2026-08-31/findings.md`.** The
> deliberate run was made and the guess above was wrong for a top-level tool: a
> `tool_progress` frame IS emitted, on a measured 30.002 s cadence. It was right for a tool
> nested inside a `Task` subagent, where 70.208 s of work produced zero frames and 67.131 s
> of silence. Read the closure before sizing anything; the row in §4 is superseded by it.

**C3 — The watermark denominator lags by one turn.** `used` is available mid-turn. `size`
(`contextWindow`) appears in `result.modelUsage`, i.e. only once a turn has finished; the
control `initialize` response lists five models but **carries no `contextWindow` field**
(`run9`, verified). So the very first turn of a fresh lease has a numerator and no
denominator. Proactive rotation (§3.2) is a many-turn concern, so this is small — but it is
real and it is not in the design.

**C4 — One malformed stdin line kills the child.** Observed: writing `this is not json at
all` produced `Error parsing streaming input line (type=unknown, 23 chars): SyntaxError` on
stderr and the process **exited 1**, having written **zero bytes** to stdout
(`raw/run12-malformed-stdin.{stderr,exit,stdout.jsonl}`). RichOS controls everything it writes, so
this is not a likely fault — and it is a *positive* termination signal (child exit + stdout
EOF), which is exactly what §5.2 demands. It is listed because a long-lived lease that dies
on one bad byte is a fragility worth knowing before it is discovered in front of the CEO.

---

## 8. The decision that is not mine

Deleting the adapter trades **100 third-party npm packages the CEO would sign** for
**a dependency on an undocumented flag of a self-updating first-party binary**.

`--permission-prompt-tool stdio` is what arms the `can_use_tool` channel, and it **does not
appear in `claude --help`** (verified — the flag is accepted and works, but is undocumented).
The binary also updates itself: three versions sit side by side in
`~/.local/share/claude/versions/` (2.1.246, 2.1.250, 2.1.251), and RichOS would be pinned to
whatever the operator's install last fetched.

Those are different *kinds* of risk, not more and less of one. The npm tree is ~90 publishers
who can each push a version RichOS's caret range would accept. The native binary is one
first-party publisher, Apple-signed, already trusted on this machine — but its stdio contract
is partly undocumented and moves without our say-so. **Which risk RichOS should hold is the
CEO's call, and I am not making it here.**

---

## 9. What this spike does NOT establish

Named so that nobody reads a stronger claim into it than the evidence carries:

- **Nothing about Windows or Linux.** Everything above is macOS arm64.
- **Nothing about long-running tools** (see C2).
- **Nothing about `plan`** (see the table; `TodoWrite` was unavailable).
- **Nothing about crash/rotation behaviour under load** — no rotation, no watermark-triggered
  rotation, and no mid-turn crash was exercised.
- **Nothing about MCP servers.** Three appeared as `needs-auth` in `system/init` and were
  never used.
- **No performance comparison against the adapter.** No ACP turn was run today; the ACP
  column is the 2026-08-28 probe's, and the two were not run under matched conditions.
- **`acp.rs` was not modified, the adapter was not deleted, and no shipped behaviour
  changed.** Both gates were re-run green afterwards: `cargo test -p richos-core` **543
  passed**, and `node run.js` in `app/ui/tests` **17 suites / 325 checks, none skipped**.

## 10. One probe artifact, corrected

`tools/native-claude-stdio`'s console line prints `ctxWindow` by taking an arbitrary entry
from the `modelUsage` map, so its stderr shows `ctxWindow=200000` — that is
`claude-haiku-4-5`'s window, from a background side-call, not the session model's. The
committed raw JSONL has both, and the session model `claude-sonnet-5` reports
**`contextWindow: 1000000`** (`run9:31`). The table above uses the correct figure. The
probe's display was left as it ran rather than tidied after the fact.
