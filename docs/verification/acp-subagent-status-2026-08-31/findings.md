# Does the ACP adapter emit intermediate tool status inside a subagent?

**Observation, 2026-08-31. This closes the case
`../native-claude-tool-status-2026-08-31/findings.md` §6.3 and §8 left open, and it is the last
piece of evidence the two parked decisions were waiting on
(`richos-hq/wiki/open-items.md` row 3.13).**

Yesterday's artifact measured the native binary, found the heartbeat, then found a hole it
refused to fill by reasoning:

> Subagents are the regression risk, and it is unmeasured on BOTH sides — no ACP run drove a
> long subagent either, and two unmeasured cases are not a comparison. **That missing run is
> against the adapter, not the binary.**

That run has now been made. Four of them.

---

## The answer — option 2 of the three: **ACP is silent too**

**The identical Bash command, held for 70.297 s inside a `Task` subagent, produced zero
intermediate status frames on the ACP wire — 70.292 s in which nothing of any kind arrived.
Repeated once: 70.280 s, zero frames, 70.252 s of silence.** Against the native path's zero
frames over the same shape, **both paths behave the same here.** The regression risk that
parked the decision does not exist.

**And the run answers more than it was asked.** The same probe, given the same command at the
**top level**, recorded **two `in_progress` frames on a 30.003 s cadence** — so the ACP path
matches the native path on that case too. The two paths are not merely equivalent inside a
subagent; on this evidence they are equivalent on **both** sides of the split, because the
adapter is forwarding the very heartbeat yesterday's artifact discovered.

That second result **falsifies two claims in yesterday's §5**, and they are the two that made
the native path look better. They are corrected in §5 below.

---

## 1. The measurement

Four runs, raw JSON-RPC committed unedited under `raw/`, indexed by `raw/README.md`, each with a
`.timings.tsv` of per-message read offsets.

The instrument is **`app/acp-adapter/probe-machinery.js`, unmodified** — the same file that
produced the five 2026-08-28 captures — driven only through its `PROBE_PROMPT` variable. Its
permission policy is `acp.rs`'s own: auto-approve the first `allow*` option (`acp.rs:469-479`).
Adapter **0.70.0**, the version the 2026-08-28 probe recorded
(`../acp-emission-probe-2026-08-28/observed-kinds.json:5`), fronting the same `claude` **2.1.251**
the native runs measured.

The workload is yesterday's workload, unchanged, which is what makes the two artifacts
comparable at all:

```
for i in $(seq 1 14); do echo tick-$i; sleep 5; done
```

14 iterations × 5 s = **70.000 s** expected. Measured, permission-allow to `completed`:

| run | shape | measured | overhead vs 70.000 s | `in_progress` frames |
|---|---|---|---|---|
| **A** (`raw/acp-run-a-longtool-toplevel.jsonl`) | top level | **70.265 s** | 265 ms | **2** |
| **B** (`raw/acp-run-b-longtool-subagent.jsonl`) | inside a `Task` | **70.297 s** | 297 ms | **0** |
| **C** (`raw/acp-run-c-longtool-subagent-repeat.jsonl`) | B repeated | **70.280 s** | 280 ms | **0** |
| **D** (`raw/acp-run-d-longtool-toplevel-repeat.jsonl`) | A repeated | **70.252 s** | 252 ms | **2** |

**A and B are a controlled pair whose only variable is nesting: 70.265 s against 70.297 s, 32 ms
apart.** Both the positive and the negative reproduce. Set beside yesterday's three native runs
(70.228 s, 70.208 s, 70.268 s), all seven durations fall inside an 89 ms band.

## 2. What ACP emits for a long top-level tool, and the cadence re-derived

Verbatim from `raw/acp-run-a-longtool-toplevel.jsonl:20`:

```json
{"jsonrpc": "2.0", "method": "session/update",
 "params": {"sessionId": "5e9c9268-bf15-4c64-9bfe-77569ab6815b",
   "update": {"sessionUpdate": "tool_call_update",
     "toolCallId": "toolu_012UTQENcfaLUDaUSSuxdpYE",
     "status": "in_progress",
     "_meta": {"claudeCode": {"toolName": "Bash",
                              "toolResponse": {"elapsedTimeSeconds": 30}}}}}}
```

| run | frame 1 | frame 2 | measured interval | `elapsedTimeSeconds` |
|---|---|---|---|---|
| A | allow **+30.008 s** | allow **+60.011 s** | **30.003 s** | 30, 60 |
| D | allow **+30.008 s** | allow **+60.008 s** | **30.000 s** | 30, 60 |

Offsets are from the `session/request_permission` reply, which is within milliseconds of the
tool's actual start. The native runs measured 30.002 s and 30.001 s for the same interval; the
binary's declared constant is `HTe = 30000` ms. **30,000 ms declared; 30.003 s and 30.000 s
measured across four ACP firings — 3 ms and 0 ms of drift.** The constant is inference from the
binary (yesterday's §7); these two intervals are observation.

The arithmetic consequence carries over unchanged and it is why nobody had seen this before: a
tool of duration *D* yields `floor(D / 30)` frames, so **a tool that runs 29 s yields none**.
**The longest single tool across all five 2026-08-28 runs was 1.584 s**
(`../acp-emission-probe-2026-08-28/run1.raw.jsonl`, `toolu_01TiBQt6X8cw47MkhqwTUjV9`), and its
longest whole turn was 33.362 s. A 1.584 s tool is nineteen times below the sampling interval.
That is the entire reason that probe recorded no `in_progress` — it was never evidence about
the adapter, it was a sample below the sampling interval, the same trap yesterday's §2
identified for the native path's sub-second `echo`.

**One place ACP is easier to consume than the native wire.** Yesterday's §1 records a trap: the
native `tool_progress` frame's own `tool_use_id` is a synthetic `<real-id>-heartbeat-<n>` that
matches no row, and a consumer must key on `parent_tool_use_id` instead. **The adapter has
already resolved it** — the frame above carries `toolCallId: toolu_012UTQ…`, the real id of the
row it belongs to, the same field `acp.rs` keys on everywhere else. The trap does not exist on
this path.

## 3. The subagent case, stated so it is evidence rather than an absence of looking

In runs B and C, **not one inbound message of any kind** arrived between the permission reply
and the tool's completion:

| | B | C | native run15 |
|---|---|---|---|
| nested tool duration | 70.297 s | 70.280 s | 70.208 s |
| intermediate status frames | **0** | **0** | **0** |
| longest window with no frame at all | **70.292 s** (+5.825 → +76.117) | **70.252 s** (+6.888 → +77.140) | 67.131 s |

**The instrument was demonstrably looking.** This is the point runs A and D exist to make: the
same probe file, the same client policy, the same session shape, the same `analyse.py` counting
the frames — and it caught two of them, twice, when they were there. A negative from an
instrument with a proven positive control is an observation. The frame that would have appeared
in B is exactly A's frame with `toolCallId` equal to the nested Bash's
`toolu_01DJuur1pK31mQ2N6sTWekgG` (`raw/acp-run-b-longtool-subagent.jsonl:18`), at offsets near
+35.8 s and +65.8 s. `raw/acp-run-b-longtool-subagent.timings.tsv` has 27 inbound rows across
78.6 s and none of them is one.

**The adapter does surface the nesting itself** — the inner Bash arrives as a first-class
`tool_call` carrying `_meta.claudeCode.parentToolUseId` pointing at the `Agent` row
(`raw/acp-run-b-longtool-subagent.jsonl:18`), and the `Agent` row's completion carries
`totalDurationMs: 73864`, `totalToolUseCount: 1` and the subagent's `agentId`
(`:23`). Structure, yes. Liveness during the 70 s, no.

**No ACP analogue of `system/task_progress` appeared.** `otherInboundNotifications` is empty in
all four `.summary.json` files — the adapter's whole vocabulary in these runs is
`session/update` plus one `session/request_permission`. On the native path that frame fired
once, at 8.456 s, *before* the long tool started. So the delta is one frame that arrives before
the silence rather than during it: **neither path gives a live signal while a subagent sits on a
long tool.**

## 4. The comparison, which is the thing that was missing

| case | native (2026-08-31) | ACP adapter (this run) | verdict |
|---|---|---|---|
| top-level tool ≥ 30 s | 2 frames, 30.002 s cadence, `elapsed_time_seconds` | 2 frames, 30.003 s cadence, `elapsedTimeSeconds` | **equivalent** (ACP keyed on the real id; native needs `parent_tool_use_id`) |
| any tool < 30 s | none | none | **equivalent** — and this is most tools |
| tool inside a `Task` subagent | 0 frames, 67.131 s silent | 0 frames, 70.292 s / 70.252 s silent | **equivalent** |

**On intermediate tool status, there is no case in which these two paths differ in what the CEO
would see.** That is the sentence the parked decision was waiting for.

## 5. Two corrections to yesterday's §5

Both were reasonable readings of the evidence available yesterday. Both are now measured wrong,
and both ran in the native path's favour, so leaving them uncorrected would tilt the ruling.

1. > *"The native path would populate it, for the first time, for any top-level tool held ≥30 s."*

   **The ACP path populates it too**, and did so before the native path was ever considered.
   Runs A and D, twice each. `ActivityState::Running` is not an unreachable branch on the
   shipped path; it is a branch nothing in the 2026-08-28 sample ran long enough to reach.

2. > *"…and would additionally supply `elapsed_time_seconds`, an authoritative per-tool duration
   > from the agent's own clock, which ACP supplies on no field at all."*

   **ACP supplies it**, at `update._meta.claudeCode.toolResponse.elapsedTimeSeconds`, with the
   values 30 and 60 in both A and D — the same numbers, from the same clock, one nesting level
   down in the envelope.

**Two source comments are now measured-stale**, and are flagged rather than edited because this
task is observation only and they are shipped source: `machinery.rs:54` and the same sentence
repeated at `timeline.rs:272`, both asserting *"`in_progress` never appeared"*. That was true of
the 58 events they were written against and is false of the wire. The `34 of 58 carried no
status` half of each comment is untouched by this run and still stands.

## 6. What the shipped pipeline would do with these frames

Traced, not run end-to-end: `merge_into` (`machinery.rs:717-723`) applies `incoming.status` onto
the open row whenever it is present, and A's frame carries a status with no title, so it merges
without disturbing the row's resolved title. `activity_state_of` (`timeline.rs:1581`) maps
`ToolStatus::InProgress` to `ActivityState::Running`, and `timeline.js:376` renders that as the
word `running`.

The mapping half of that is not inference: the landed test
`activity_state_never_invents_completion` (`timeline.rs:2080-2097`) already asserts it against
`{"toolCallId":…,"sessionUpdate":"tool_call_update","status":"in_progress"}` — **the identical
field set to the frame measured here**. The merge step is read from source; I did not execute
this exact captured frame through the pipeline, and that distinction is deliberate.

**No UI surface was produced or altered by this run, so the WCAG AA contrast floor has nothing
here to bind on.** The words `running` / `queued` / `outcome not recorded` are existing rendered
strings, unchanged.

## 7. Observed vs inferred

**OBSERVED** — the bytes are under `raw/`:

- The ACP adapter emits `tool_call_update` with `status: "in_progress"` for a top-level Bash
  tool held past 30 s: twice in run A, twice in run D.
- Cadence 30.003 s (A) and 30.000 s (D), against the native path's 30.002 s and 30.001 s.
- `_meta.claudeCode.toolResponse.elapsedTimeSeconds` = 30 and 60, agreeing with our own clock.
- The frame is keyed on the row's real `toolCallId`; no synthetic id, no parent indirection.
- **Zero such frames for a 70.297 s and a 70.280 s Bash tool nested inside a `Task`, with
  70.292 s and 70.252 s in which nothing arrived at all.**
- A nested tool is still surfaced structurally, via `_meta.claudeCode.parentToolUseId`, and the
  `Agent` row closes with `totalDurationMs` / `totalTokens` / `totalToolUseCount` / `agentId`.
- No notification method outside `session/update` and `session/request_permission` appeared in
  any of the four runs.
- Every run ended `stopReason: "end_turn"`; nothing was truncated or timed out.

**INFERRED** — corroboration, never the claim:

- That the 30 s cadence originates in the binary's `HTe = 30000` (yesterday's §7) and that the
  adapter is forwarding that same heartbeat rather than generating its own. The field name
  `_meta.claudeCode.toolResponse.elapsedTimeSeconds` and the matching interval make it very
  likely; I did not read the adapter's source to confirm it.
- That the subagent exclusion has the same cause on both paths (yesterday's `if(e===yt)return _En;`).
  The *behaviour* matches on both paths; the shared cause is inference.
- That `merge_into` + `activity_state_of` would render `running` for a captured frame (§6).

## 8. What this does NOT establish

- **Nothing about a non-`Bash` tool held past 30 s** on either path. Every frame observed in
  both artifacts carried `toolName: "Bash"`.
- **Nothing about a backgrounded subagent** (`run_in_background: true`). Both B and C ran
  foreground, matching run15.
- **Nothing about a subagent that takes several steps.** Native run14 showed `system/task_progress`
  is per-step; a multi-step ACP subagent was not driven. It would not change §3 — the silence
  measured here is *within* one long tool, and steps are not a timer.
- **Nothing about `--include-hook-events`.** Not reachable through the adapter and not tried.
- **Nothing about Windows or Linux.** macOS arm64 only.
- **Nothing about future versions.** Adapter 0.70.0, binary 2.1.251. `tool_progress` is not in
  `claude --help`, so neither its presence nor the adapter's forwarding of it is contractual.
- **`acp.rs` was not modified, the adapter was not deleted, no shipped behaviour changed, and no
  UI surface was produced or altered.** Both gates re-run green afterwards: `cargo test -p
  richos-core` **543 passed, 0 failed**; `node run.js` in `app/ui/tests` **17 suites, 325 checks,
  0 failed**.
