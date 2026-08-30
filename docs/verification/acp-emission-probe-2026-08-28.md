# What the ACP adapter actually emits — measured, 2026-08-28

**Author:** Echo (Rust & Tauri desktop engineer). **Date:** 2026-08-28.
**Answers:** the verify-first caveat in `richos-hq/docs/plans/richos-techy-mode-2026-08-26.md` §1.1 —
*"the emitted subset of our actual adapter (`claude-agent-acp`) is **not verified anywhere in this
repo** … Before Phase 1 is written, run the probe with a tool-using prompt and record the observed
kinds."* (That section names a `scratch-acp/probe.js` path; the directory was renamed `app/acp-adapter/`
in `9d8fc1f`. Path moved, citation didn't.)

**Verdict up front: the §1.2 routing table HOLDS. Phase 1 is not blocked.** Every kind the table
routes exists in the adapter's emitter; no kind appeared that the table does not list; the
merge-by-`toolCallId` contract (§1.4 G2) works exactly as designed against real traffic. Three
field-level assumptions in §1.3 are wrong and are corrected below, and two routed paths produced
**zero** traffic — one of them the headline feature. Details in §4 and §5.

---

## 1. Method

**Probe:** `app/acp-adapter/probe-machinery.js` (committed with this artifact). It differs from
`probe.js` in the one way that matters: it appends **every** inbound JSON-RPC message to a JSONL file
as it arrives, tagged with an arrival index `n` and a lifecycle `phase`. `probe.js:36-38` logged
non-text kinds to stderr and nothing to disk, which is why nothing in the repo answered this
question.

- **Adapter:** `@agentclientprotocol/claude-agent-acp` **0.70.0** (installed; the manifest range is
  `^0.70.0`). `agentInfo.version` on the wire agrees: `0.70.0`.
- **Protocol:** `initialize {protocolVersion: 1}` → `{protocolVersion: 1}`. Same version `acp.rs:25`
  speaks.
- **`session/new` cwd:** `/Users/alex/ab/richos/engine` — the same cwd production uses
  (`acp.rs:314-318`). The engine ships `CLAUDE.md.template`, not a rendered `CLAUDE.md` (it is
  gitignored at the repo root), so no orchestrator persona hijacked these runs.
- **Client-directed requests answered with the same policy as `acp.rs:184-205`:** permission requests
  auto-approved by picking the first `allow*` option. *One deliberate difference, named:* the probe
  answers `fs/read_text_file` with the file's **real** contents, where `acp.rs:199` answers with an
  empty string. It made no difference — see §5.2, neither method was ever called.
- **Five runs**, each a fresh adapter process and a fresh session. Each run opens a 3-second quiet
  window after `session/new` and another after the prompt response, so between-turn traffic (§1.5)
  has somewhere to land in the record.

**Evidence, committed:** `docs/verification/acp-emission-probe-2026-08-28/`
— `run{1..5}.raw.jsonl` (every message, in arrival order), `run{1..5}.prompt.txt` (the exact prompts,
verbatim, so every run is reproducible), `observed-kinds.json` (counts, phase histogram, and up to
three representative payloads per kind).

Reproduce a run:

```
cd app/acp-adapter && npm install
node probe-machinery.js /Users/alex/ab/richos/engine /tmp/run.raw.jsonl /tmp/run.summary.json
# PROBE_PROMPT overrides the prompt; PROBE_WRITE_TARGET the write path.
```

### 1.1 The prompts

| Run | Aimed at | Prompt (see `runN.prompt.txt` for the verbatim text) |
|---|---|---|
| 1 | broad tool use | five steps: read `VERSION`, grep, `echo … && uname -s`, write a file under `/tmp`, summarize |
| 2 | `agent_thought_chunk`, `plan`, `fs/read_text_file` | "think hard"; use **TodoWrite**; use the **Read** tool, not bash |
| 3 | `plan` | force `TodoWrite` by name, marking each item in progress then complete |
| 4 | `agent_thought_chunk` | `MAX_THINKING_TOKENS=10000`, a hard derivation, "think as hard and as long as you can", no tools |
| 5 | `status: "failed"` | one bash command guaranteed to exit non-zero |

Every run ended `stopReason: "end_turn"`. No run errored.

---

## 2. What was observed

Union across all five runs (inbound only):

| `sessionUpdate` | Count | Runs | Phases |
|---|---|---|---|
| `agent_message_chunk` | 52 | 1,2,3,4,5 | prompt |
| `usage_update` | 50 | 1,2,3,4,5 | prompt |
| `tool_call_update` | 46 | 1,2,3,5 | prompt |
| `plan` | 15 | 3 | prompt |
| `tool_call` | 12 | 1,2,3,5 | prompt |
| `available_commands_update` | 10 | 1,2,3,4,5 | **session_new (1/run)**, prompt (1/run) |
| `session_info_update` | 5 | 1,2,3,4,5 | **post_stop (1/run)** |

| Client-directed request | Count | Runs | Phases |
|---|---|---|---|
| `session/request_permission` | 7 | 1,2,3,5 | prompt |

No other inbound notification method was ever seen. No unparsable line was ever received.

---

## 3. The three answers the task asked for, explicitly

### 3.1 In the §1.2 table AND observed

`agent_message_chunk`, `tool_call`, `tool_call_update`, `plan`, `usage_update`,
`available_commands_update`, `session_info_update`, and the request method
`session/request_permission`.

### 3.2 In the §1.2 table and NOT observed — **absence of evidence, not evidence of absence**

Each of these exists in the adapter's emitter; I grepped the pinned bundle and cite the emission
site. None of them is missing from the product; each simply produced no traffic in these five runs.

| Not observed | It exists here | Why it did not fire |
|---|---|---|
| `agent_thought_chunk` | `node_modules/@agentclientprotocol/claude-agent-acp/dist/acp-agent.js:6462-6473` | **See §4.1 — this is the finding that matters.** |
| `current_mode_update` | `acp-agent.js` (4 references) | Fires on a mode change. Nothing changed mode; the probe never sent `session/set_mode`. |
| `config_option_update` | `acp-agent.js` (2 references) | Same class — a config option has to change. |
| `user_message_chunk` | `acp-agent.js` (5 references) | Emitted on session replay/`session/load`. The probe only ever opened fresh sessions. §1.2 **drops** it anyway, so this changes nothing. |
| `fs/read_text_file` | `acp-agent.js:555-559`, `:4002-4004` | **See §5.2 — zero traffic across five runs with the capability declared and the Read tool exercised.** |
| `fs/write_text_file` | `acp-agent.js:558-560`, `:4006-4008` | Same. The Write tool ran (run 1) and did its own IO. |

### 3.3 Observed and NOT in the §1.2 table

**None.** Every `sessionUpdate` kind and every client-directed request method observed across five
runs is already named in §1.2. `observed-kinds.json` records this as
`"observedKindsNotInTable": []` / `"observedMethodsNotInTable": []`.

The consequence for §1.4 G5 (*"an unknown kind is retained, not discarded"*) is worth stating
precisely: G5 is **not** contradicted, and it is also **not** exercised — the `Unknown` route remains
a designed-for path with no observed traffic behind it. It is built anyway, and the honest thing to
say about it today is that its first real test will be an adapter upgrade, not this probe.

---

## 4. Findings the CEO needs before a renderer is briefed

### 4.1 `agent_thought_chunk` is structurally empty today — the "thinking" row will not appear

Zero thought chunks across five runs, including run 4, which existed only to elicit one:
`MAX_THINKING_TOKENS=10000`, an explicit "think as hard and as long as you can", a genuinely hard
derivation, and no tools to distract. 17 `agent_message_chunk`s came back. Zero
`agent_thought_chunk`.

The cause is in the adapter's own source, with its own comment (`acp-agent.js:6461-6473`, verbatim):

```
case "thinking":
case "thinking_delta": {
    // Recent models default `thinking.display` to "omitted", which streams
    // signature-only thinking blocks whose text is empty.
    if (chunk.thinking && !containsFileChangeAuditToolUse) {
        update = { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: chunk.thinking } };
    }
```

The streaming path carries the same guard and the same reason (`acp-agent.js:2918-2926`: *"Skip empty
deltas (some gateways emit empty thinking chunks …)"*). So the update is emitted **only** when the
model returns thinking text, and recent models return a signature with the text omitted.

**What this costs.** §1.2 justifies routing this kind as *"the 'what is he actually thinking' the CEO
loses when he leaves the terminal"*, and §5's day-one mockup opens with `● thinking ⌄`. On today's
adapter and today's default model, that row never renders, because there is nothing to render.

**What I did about it.** I built the route anyway. It costs nothing, it is in the table, and the day
a model or adapter starts emitting thought text it is captured with no data hole — which is the whole
argument for landing routing early. But nobody should brief a renderer expecting a thinking block,
and §1.2's justification for this row should be re-read with this in front of it. **This is a gap in
the design's premise, not in its mechanism, and it is the CEO's to weigh.**

### 4.2 §1.5 is confirmed by data — between-turn traffic is real, and one update lands after the turn is over

In **every** run:

- one `available_commands_update` arrives in the `session_new` window, before any prompt exists;
- one `session_info_update` arrives in the `post_stop` window — **after** the `session/prompt`
  response has already been returned.

`acp.rs:150` only delivers an update when `current_prompt` is `Some`, and `acp.rs:164-173` sets
`current_prompt` to `None` the instant it sends `ChunkMsg::Done`. So `session_info_update` reaches no
sink at all today, in every turn, on every session. §1.5 predicted this class; it is not
hypothetical, it is 100% of runs.

(The `session_info_update` payload is `{title, updatedAt}`, where `title` is the first ~150 characters
of the prompt. That is the adapter naming the session after what was asked.)

### 4.3 §2.3's volume estimate is low, by roughly 1.5–2.3×, and here is the arithmetic

Machinery records per turn (everything except `agent_message_chunk`, plus client-directed requests):

| Run | tool calls | machinery records |
|---|---|---|
| 5 | 1 | 14 |
| 2 | 2 | 19 |
| 3 | 4 | 66 (TodoWrite: 15 `plan` + 26 `usage_update`) |
| 1 | 5 | 39 |
| 4 | 0 | 7 |

Fit a line through runs 5 and 1 (the two clean tool-using endpoints):

```
marginal = (39 − 14) ÷ (5 − 1) = 25 ÷ 4 = 6.25 machinery records per tool call
fixed    = 14 − 6.25 × 1       = 7.75 machinery records per turn
```

Held-out checks: run 2 predicts 7.75 + 6.25×2 = **20.25** vs **19** observed (−6.2%); run 4 predicts
**7.75** vs **7** observed (−9.7%). Run 3 predicts 32.75 vs 66 observed (+102%) — the TodoWrite
outlier, where `plan` is re-emitted in full on every todo mutation.

§2.3 measured **741 top-level `tool_use` calls** on the heaviest day (2026-08-26). So:

```
journal LINES from tool calls alone = 741 × 6.25 = 4,631 per day
                                       (before per-turn overhead, before any plan traffic)
projected ROWS after the §1.4 G2 merge ≈ 741 per day (one per toolCallId)
```

§2.3 estimates "~2,000–3,000 records/day". That number sits between the two, so it is ambiguous about
which it counts. Against **lines** — which is what §1.4 G6's append-only journal actually writes — the
measured marginal rate alone is **1.5–2.3× its top end**, and at §2.3's own 250–450 bytes/record that
is **1.2–2.1 MB/day, not 0.6–1.2 MB/day**.

This changes no decision: it is still 6–10× smaller than verbatim retention, and Tier A is still
cheap enough to keep forever (§2.4). But the number in §2.3 should be read as roughly half the real
line rate.

---

## 5. Corrections to §1.3's record and §1.2's assumptions

All five are absorbed by §1.4 G2's merge rule. None of them breaks routing. All five change what an
implementation must actually do.

### 5.1 A `tool_call` open event carries no useful title and no arguments

Every single one, in all five runs:

```json
{"_meta":{"claudeCode":{"toolName":"Bash"}},"toolCallId":"toolu_01SRK…","sessionUpdate":"tool_call",
 "rawInput":{},"status":"pending","title":"Terminal","kind":"execute","content":[]}
```

`rawInput` is `{}`. `title` is a class placeholder — `"Terminal"` for Bash, `"Preparing file…"` for
Write, `"Read File"` for Read. §1.3's example title (`"Read app/crates/richos-core/src/acp.rs"`) is
only ever true **after** a later `tool_call_update` supplies it:

```json
{"toolCallId":"toolu_01SRK…","sessionUpdate":"tool_call_update",
 "rawInput":{"command":"cat /Users/alex/ab/richos/engine/VERSION"},
 "title":"cat /Users/alex/ab/richos/engine/VERSION","kind":"execute"}
```

**Consequence:** merging is mandatory, not an optimization. A projection that rendered the open event
alone would show the CEO a column of `Terminal / Terminal / Terminal`.

### 5.2 The observed lifecycle is `pending → (status absent ×2–3) → completed | failed`

Twelve tool-call lifecycles across four runs. Every one of them:

```
tool_call:pending  →  tool_call_update:<no status field>  ×2–3  →  tool_call_update:completed|failed
```

Status-field tally across runs 1/2/3/5 (58 events = 12 `tool_call` + 46 `tool_call_update`):
`pending` 12, **absent 34**, `completed` 11, `failed` 1.

- **`failed` is confirmed** (run 5, `cat` of a missing file): `{"status":"failed","rawOutput":"Exit
  code 1\ncat: …: No such file or directory"}`. The adapter also emits it on permission denial
  (`acp-agent.js:2259`).
- **`in_progress` was never observed** in twelve lifecycles. It is emitted only from long-running-tool
  "beat" messages (`acp-agent.js:3311`); short tools never produce one. Not missing — just not
  reachable by anything these runs ran.

**Consequence:** §1.2's *"Lifecycle: `pending → in_progress → completed | failed`"* describes the
declared enum, not the observed path. Two thirds of `tool_call_update`s carry **no `status` field at
all**, so §1.4 G2's *"last-write-wins per field **present** in the update, absent fields untouched"* is
load-bearing: a naive whole-record overwrite would blank the status back to nothing on every content
update, and the CEO's status dot would flicker off.

### 5.3 `locations` is an array of objects, not `Vec<String>`

Observed: `[{"path":"/Users/alex/ab/richos/app/crates/richos-core/src/util.rs","line":1}]`. §1.3
declares `locations: Vec<String>`. The `line` is present on Read, absent on Write. Extract `.path`.

### 5.4 The payload fields are `rawInput` / `rawOutput`

Not `input`/`output`. `content` is a separate array of `{type:"content"|"diff", …}` display blocks.

### 5.5 The real tool name lives in `_meta`, not in `kind`

ACP `kind` is a coarse class — `execute`, `edit`, `read`, `other`. The actual tool name is
`_meta.claudeCode.toolName`: `Bash`, `Write`, `Read`, `ToolSearch` observed. Anything that wants to
say "bash" rather than "execute" has to read the vendor `_meta`.

### 5.6 `session/request_permission` params are `{sessionId, toolCall, options}`

`toolCall` embeds the full open tool call including `toolCallId` and the resolved `title`, so §1.2's
`PermissionRequested { title, options, chosen, auto: true }` can be built from it **and** linked back
to its tool call. Observed option kinds: `reject_once`, `allow_once`, `allow_always`. Seven requests
across the four tool-using runs — the adapter does ask, and `acp.rs:188-198` does auto-approve,
exactly as gap #1 says.

### 5.7 `fs/read_text_file` and `fs/write_text_file` never fired

Zero across five runs, with `clientCapabilities.fs.readTextFile` and `.writeTextFile` both declared
(`acp.rs:235`) and with the Read tool (run 2) and the Write tool (run 1) both actually exercised. The
adapter has the outbound proxies (`acp-agent.js:555-559`, `:4002-4008`) but nothing in its bundle
calls them on the normal tool path — the Claude CLI underneath does its own filesystem IO.

**Consequence:** §1.2's `ClientFsCall` route is real but, on this adapter version, inert. I built it —
it is four lines and it is in the table — and I am naming it as a route with no observed traffic
rather than letting it look like a verified path.

### 5.8 `usage_update` carries context occupancy, not token counts

`{"used":30477,"size":1000000}` — occupancy of the context window, sometimes with `cost` and
`_meta._claude/rateLimit`. Separately, the `session/prompt` **response** carries a real
`usage: {inputTokens, outputTokens, cachedReadTokens, cachedWriteTokens, totalTokens}` which
`acp.rs:270-276` discards, exactly as `spine.rs:59-66` admits. **Wiring either of these is Phase 2 and
is not in this commit.** The chars÷4 proxy and its honesty comment are untouched.

---

## 6. Gate verdict

The task carried a stop condition: *contradict §1.2 materially — a routed kind that does not exist, a
kind carrying different data than assumed, or a lifecycle that does not work as
`pending → in_progress → completed | failed` — and stop.* Taken prong by prong:

1. **A routed kind that does not exist:** no. All four Phase-1 kinds exist in the adapter's emitter;
   three produced live traffic and the fourth (`Unknown`) is a catch-all by construction.
   `agent_thought_chunk` exists and is emitted — it is the *model* that supplies no text (§4.1). That
   is a gap in the design's premise for one row, reported loudly, not a broken routing rule.
2. **Different data than assumed:** yes, at field level — §5.1–5.8, six corrections. Every one is
   absorbed by the merge rule the design already specifies. None changes where an update is routed.
3. **A lifecycle that does not work:** no. The observed path is a strict subset of the declared enum,
   `failed` is confirmed, and `in_progress`'s absence has a sourced cause. The design's merge rule
   handles the status-absent updates that dominate the traffic — in fact it is the reason it works.

**So the gate is not tripped, and Task 2 proceeds** — with §4.1 and §5.7 carried into the handoff as
named gaps rather than quietly absorbed.
