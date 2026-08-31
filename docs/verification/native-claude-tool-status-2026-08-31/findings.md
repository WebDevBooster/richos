# Does the native `claude` stdio emit intermediate tool status?

**Observation, 2026-08-31. This closes caveat C2 of
`../native-claude-stream-json-2026-08-31/findings.md` §7.**

> **FORWARD POINTER, added 2026-08-31 after the ACP run this document asks for.** §6 case 3 and
> §8 bullet 1 are now answered by `../acp-subagent-status-2026-08-31/findings.md`: the ACP
> adapter is silent inside a subagent too, so **both paths behave the same there.** That run
> also measured two claims in **§5 wrong**, both in the native path's favour — ACP *does* reach
> `in_progress` for a top-level tool held ≥30 s, and it *does* supply the per-tool elapsed
> seconds. Read §5 with that correction. **Nothing below this line has been edited**; the
> measurements it reports still stand.

C2 said:

> **NOT OBSERVED**, not "absent": no intermediate tool status. I did not run a tool long
> enough to prove there is none. **Needs one deliberate run before sizing the port.**

That run has now been made. Four of them.

---

## The answer — option 1 of the three: **intermediate status IS emitted**

The native binary emits a top-level **`tool_progress`** frame on the same stream-json stdio,
on a **30-second cadence**, while a tool runs. C2's guess that the techy view "would show
started and then finished with nothing between" was **wrong for a top-level tool** — and
**right, exactly and only, for a tool nested inside a `Task` subagent**, which is the case
this document adds.

Observed frame, verbatim from `raw/run13-longtool-bash-ticking.jsonl:22`:

```json
{"type": "tool_progress",
 "tool_use_id": "toolu_01KJdbWL6beA2nhNoi3QdpkW-heartbeat-0",
 "tool_name": "Bash",
 "parent_tool_use_id": "toolu_01KJdbWL6beA2nhNoi3QdpkW",
 "elapsed_time_seconds": 30,
 "heartbeat": true,
 "session_id": "83eb151a-bfc4-4cd7-a7b1-999753c2862b",
 "uuid": "3f6352f0-498b-42b7-8c03-91336dcb86c6"}
```

**The trap, and it would have cost a day:** the frame's own `tool_use_id` is a synthetic
`<real-id>-heartbeat-<n>` that matches no row anywhere. The row it belongs to is
**`parent_tool_use_id`**. A consumer that keys on `tool_use_id` — the obvious choice, and the
field `acp.rs` keys on everywhere else — silently updates nothing. `spike/native-claude-stdio/
src/bin/tool_status.rs` keys on `parent_tool_use_id` and its live row moves; that is what the
`ROW UPDATE` lines in the Rust run are.

---

## 1. The measurement

Four runs, raw output committed unedited under `raw/`, indexed by `raw/README.md`, each with
a `.timings.tsv` of per-line read offsets. Same binary, same flags, same auth conditions as
the 2026-08-31 spike — nothing was added or removed, so the two compose.

**The workload is one deliberately long tool**, which is the whole point: every tool in the
first spike finished in well under a second, so the question was never actually put.

```
for i in $(seq 1 14); do echo tick-$i; sleep 5; done
```

14 iterations × 5 s = **70.000 s** expected. Measured, permission-`allow` to `tool_result`:

| run | measured | overhead vs 70.000 s |
|---|---|---|
| run13 (top level, Python driver) | **70.228 s** | 228 ms |
| run15 (same command, inside a `Task`) | **70.208 s** | 208 ms |
| run16 (top level, Rust driver) | **70.268 s** | 268 ms |

The three workloads are the same to within 60 ms. That matters for §3: run13 and run15 are a
controlled pair whose only variable is nesting.

## 2. The cadence, re-derived rather than trusted

| run | heartbeat 1 | heartbeat 2 | interval |
|---|---|---|---|
| run13 | +30.004 s | +60.006 s | **30.002 s** |
| run16 | +30.021 s | +60.022 s | **30.001 s** |

Offsets are from the `can_use_tool` **allow** (run13) and from row-open (run16); both are
within 15 ms of the tool's actual start. `elapsed_time_seconds` reported by the frames was
`30` and `60` — the child's own count and our wall clock agree.

The binary carries the constant this comes from: `var HTe=30000;` immediately above
`setInterval(...,HTe)` in the heartbeat installer (`2.1.251` at byte offset 160805400).
**30,000 ms declared, 30.002 s and 30.001 s measured — 2 ms and 1 ms of drift across four
firings.** The constant is inference from the binary; the two intervals are observation, and
they are what the claim rests on.

**Consequence of a fixed 30 s cadence, and it is arithmetic, not opinion:** a tool of
duration *D* emits `floor(D / 30)` frames. **A tool that runs 29 s emits none at all.** The
first spike's `echo` (`../native-claude-stream-json-2026-08-31/raw/run3:13,17`, sub-second)
producing nothing was never evidence of absence — it was a tool three orders of magnitude
below the sampling interval.

## 3. The hole this run found, which is bigger than the one it closed

**Run15 is run13 with one variable changed: the identical Bash command, running for 70.208 s
against run13's 70.228 s, nested inside a `Task` subagent instead of called at the top level.**

| | run13 (top level) | run15 (inside `Task`) |
|---|---|---|
| tool + duration | Bash, 70.228 s | Bash, 70.208 s |
| `tool_progress` frames | **2** | **0** |
| longest gap with no frame of any type | 30.0 s | **67.131 s** (`11.533` → `78.664`) |

Nothing at all arrives for 67 seconds. The `system/task_progress` frame is not a
substitute: it fired **once**, at 8.456 s, before the long tool started, and is emitted per
subagent *step* rather than on a timer — run14 shows two of them for a subagent that took two
steps, run15 shows one for a subagent that took one. A subagent that sits on a single long
tool emits exactly one, up front, and then nothing.

This is the inverse of the intuition. **The longest-running work RichOS can dispatch — a
delegated subagent — is the one case with no live signal at all.** The binary explains it:
the heartbeat installer opens with `if(e===yt)return _En;` — a no-op for one specific tool
name — and `yt` is used as the `tool_name` of the `subagent_retry` variant, i.e. the Task
tool. That the Task tool itself is excluded is inference from that line; that a Bash tool
*nested inside* one also gets nothing is **observed**, in run15, and is more than that line
predicts.

## 4. The negative, stated so it is evidence rather than an absence of looking

For run15, the frame that would have appeared, had it existed, is **exactly the run13 frame**:
same `type`, same `tool_name: "Bash"`, `elapsed_time_seconds: 30` then `60`, with
`parent_tool_use_id` equal to the inner Bash's `toolu_018gcsd9RxsxE32LeDSCXP4v`
(`raw/run15-longtool-task-foreground.jsonl:27`), at read offsets near 38.5 s and 68.5 s. The
reader that captured run13 and run15 is the same file, unmodified between runs; it logs every
line it reads before it classifies anything, and `raw/run15-...timings.tsv` has 32 rows over
80.657 s with no `tool_progress` row among them. The instrument was looking; nothing came.

Two things were **not** observed and are recorded as such, not as absences:

- **`bash_progress`.** The binary's engine converts an internal `bash_progress` /
  `powershell_progress` event into a `tool_progress` frame (offset 166602400 ff.), and our
  command wrote a line every 5 s — yet no non-heartbeat `tool_progress` arrived. Whatever
  gates the shell generator's progress yields was not met by 14 short lines over 70 s. Note
  that even if it fired, the engine's conversion **drops `output`** and forwards only
  `elapsed_time_seconds` and `task_id`, so it would not carry partial tool output onto this
  wire.
- **A non-`Bash` top-level tool held past 30 s.** The heartbeat installer is generic in its
  argument (`aFt({toolName, toolUseID, abortSignal, onProgress})`) so it should fire for any
  tool, but every heartbeat observed here carried `tool_name: "Bash"`. Generic-ness is
  inference from one line of decompiled code; do not report it as measured.

## 5. What `acp.rs` would consume — and the one place it is better than today

The Rust probe (`spike/native-claude-stdio/src/bin/tool_status.rs`) is deliberately
`acp.rs`-shaped — spawn → one reader thread → dispatch → per-turn mpsc, same first-`allow*`
auto-approve policy (`acp.rs:469-479`) — and keeps the one piece of state a live renderer
needs. Its output, verbatim (`run16`):

```
[  2.941] ROW OPEN   Bash (toolu_014B6WWbqmUSkLXEVCih1Hoe)
[  2.955] can_use_tool "Bash" -> ALLOW
[ 32.962] ROW UPDATE Bash -> running 30s (heartbeat=true) [wall since open 30.021s]
[ 62.963] ROW UPDATE Bash -> running 60s (heartbeat=true) [wall since open 60.022s]
[ 73.210] ROW CLOSE  Bash after 70.268s wall, 2 intermediate update(s)
```

Mapped onto the landed spine: a `tool_progress` frame is what
`machinery.rs`'s merge would fold into the row keyed by `parent_tool_use_id`, setting
`ToolStatus::InProgress` (`machinery.rs:134,144`), which `timeline.rs:1581` maps to
`ActivityState::Running` and `timeline.js:376` renders as the word `running`.

**And that state is, in practice, unreachable on the path RichOS ships today.** Its own
measurement says so: *"34 of 58 observed tool events carried NO `status`, and `in_progress`
never appeared"* (`machinery.rs:54`, repeated at `timeline.rs:272`). The ACP adapter's
`tool_call_update` carries a `status` field — but across the 2026-08-28 probe's five runs it
never once carried `in_progress`. So today a tool row goes `queued` → `outcome not recorded`
→ `done`, and `ActivityState::Running` is a branch that exists and is not taken.

**The native path would populate it, for the first time, for any top-level tool held ≥30 s** —
and would additionally supply `elapsed_time_seconds`, an authoritative per-tool duration from
the agent's own clock, which ACP supplies on no field at all.

## 6. The product consequence for the live rows

The brief's premise — *"if the native path only reports a tool once it has finished, those
rows arrive late or not at all"* — is now answerable, and it splits three ways.

**The `Worked for 1h 10m 7s` row itself does not move either way.** It is computed from a
local clock, `nowMs - t.startedAt` (`app/ui/timeline.js:156`), against the turn's
`started_at`/`active_ms` in the ledger. No tool event feeds it. Whatever happens to tool
status, `Working for …` keeps ticking and `Worked for …` stays exact. That premise is worth
correcting before the CEO rules on it: **the risk was never to the duration row, it was to the
activity rows underneath.**

For those rows:

1. **Top-level tools ≥ 30 s — better than today.** They gain a live `running` state that the
   ACP path never produced, refreshed every 30 s, plus a per-tool elapsed time. This is the
   opposite of C2's fear.
2. **Any tool under 30 s — unchanged, and unchanged means silent.** No `tool_progress`, so
   the row goes straight from open to `done`. Identical to the ACP path's observed behaviour
   (`in_progress` never appeared there either), so nothing is lost — but nothing is gained,
   and this is most tools.
3. **Anything inside a delegated subagent — the real regression risk, and it is a wash on
   evidence.** 67 seconds of nothing on the native path. ACP's measured behaviour for the same
   shape is not known, because no ACP run in the 2026-08-28 probe drove a long subagent
   either. **Two unmeasured cases are not a comparison.** If the technical view's subagent
   rows matter to the CEO's decision, that is the one run still missing — and it is a run
   against the *adapter*, not the native binary.

Adjacent and unexercised: `--include-hook-events` ("Include all hook lifecycle events in the
output stream"), with the `system/hook_started` / `hook_progress` / `hook_response` frames the
binary's schema declares. It is a second potential bracket around tool execution. It was not
run — these runs used `--setting-sources ''`, under which no hooks are configured and nothing
would have fired. **Not observed, and not claimed either way.**

## 7. Observed vs inferred — the whole point of this run

**OBSERVED** (I have the bytes, committed under `raw/`):

- `tool_progress` exists on the native stream-json stdio, with the fields quoted above.
- Cadence 30.002 s and 30.001 s, four firings across two independent drivers.
- `elapsed_time_seconds` = 30 and 60, agreeing with our own wall clock.
- The row key is `parent_tool_use_id`; the frame's own `tool_use_id` is synthetic.
- An `acp.rs`-shaped Rust reader consumes them and moves a live row (run16).
- Zero frames for a 70.208 s Bash tool nested inside a `Task` (run15), against 2 for the
  same command at the top level (run13).
- `system/task_progress` is per-step, not periodic: 2 frames for a 2-step subagent (run14),
  1 for a 1-step subagent (run15).
- `system/task_started` / `task_updated` / `task_notification` / `background_tasks_changed`
  bracket tool and subagent execution, carrying `task_id`, `tool_use_id`, `status`,
  `output_file`, and for subagents a `usage {total_tokens, tool_uses, duration_ms}`.
- The model calls the Task tool by the name **`Agent`** on the wire
  (`run15:19`), while `system/init.tools` advertises it as **`Task`**. A consumer matching on
  the advertised name will not match the emitted one.

**INFERRED** (from strings and decompiled JS in the 2.1.251 binary — corroboration, never the
claim):

- `HTe = 30000` is the heartbeat constant, and the timer is `setInterval`.
- The heartbeat is generic across tools except one, guarded by `if(e===yt)return _En;`, and
  `yt` is the Task tool.
- A `bash_progress` → `tool_progress` conversion path exists and drops `output`.
- The declared wire schema is `{type:"tool_progress", tool_use_id, tool_name,
  parent_tool_use_id, elapsed_time_seconds, task_id?, uuid, session_id, heartbeat?,
  subagent_type?, subagent_retry?}` — note `task_id`, `subagent_type` and `subagent_retry`
  were never populated in any frame observed here.

## 8. What this does NOT establish

- **Nothing about the ACP adapter's behaviour on a long tool.** No ACP run was made today.
  §6's third case is genuinely open on both sides.
- **Nothing about a non-Bash tool held past 30 s** (§4).
- **Nothing about `bash_progress` firing conditions** (§4).
- **Nothing about `--include-hook-events`** (§6).
- **Nothing about Windows or Linux.** macOS arm64 only.
- **Nothing about a self-updated binary.** 2.1.251 is what is installed today; the frame is
  not in `claude --help` and is therefore no more contractual than
  `--permission-prompt-tool stdio` is (§8 of the spike, the CEO's open decision).
- **`acp.rs` was not modified, the adapter was not deleted, no shipped behaviour changed, and
  no UI surface was produced or altered** — so the WCAG AA contrast floor has nothing in this
  change to bind on. Both gates re-run green afterwards; the numbers are in the handoff.
